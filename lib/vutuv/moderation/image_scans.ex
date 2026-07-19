defmodule Vutuv.Moderation.ImageScans do
  @moduledoc """
  The AI image-moderation queue: **every** image that can become visible to
  anyone but its owner passes through here exactly once before release —
  member uploads (avatar, cover, post / job-posting / organization images)
  and machine-generated captures alike (link screenshots — otherwise a
  screenshot of an NSFW page would bypass the gate).

  The flow: the storing context sets the asset's moderation state to
  `initial_state/0` and calls `enqueue/4`; the asset stays in **limbo**
  (visible only to its owner, a placeholder for everyone else — the display
  chokepoints gate on `released?/1`) until `Vutuv.Moderation.ImageScanWorker`
  drains the row through the local Ollama vision model
  (`Vutuv.Moderation.Ollama`). A safe verdict releases the image on the spot
  (and moves it out of the quarantine tree for the nginx-served kinds); an
  unsafe verdict deletes the files immediately and notifies the owner
  (`Vutuv.Moderation.Notifier.image_rejected/1`).

  **Durable + fail-closed.** The `image_scans` row is the job (the
  `post_screenshots` pattern), so a reboot or deploy loses nothing:
  `resume_stuck/0` re-queues rows a crash left `scanning`, and
  `repair_drift/0` re-enqueues any asset sitting in `pending` without an open
  scan (the backstop for a crash between verdict and application — and for
  any future upload path that forgets to enqueue, since the gallery tables
  default their `moderation` column to `pending`). When Ollama is down the
  queue retries forever; nothing is ever auto-approved. With
  `:moderate_images` off (tests, installations without Ollama) assets are
  created `approved` and this module is dormant.
  """

  import Ecto.Query

  require Logger

  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Moderation.ImageScanWorker
  alias Vutuv.Moderation.ImageSubjects
  alias Vutuv.Moderation.Notifier
  alias Vutuv.Moderation.Ollama
  alias Vutuv.Repo

  @batch 5
  # Ollama on CPU can legitimately take minutes per image; only a claim this
  # old is presumed crashed and re-queued.
  @stuck_after_seconds 1800
  # Per-image failures (undecodable, persistent schema-violating verdict) get
  # this many tries, then the image is rejected — fail-closed, never released.
  @image_error_cap 5
  # Service failures (Ollama down/unreachable) retry forever at this pace.
  @service_retry_seconds 300

  @kinds ImageScan.kinds()
  # The member personally chose these images; a rejection deletes their
  # content, so they get the notice. Machine captures (link screenshots) are
  # our artifact of a third-party page — silently showing no preview is the
  # same UX as a failed capture, so no notice.
  @notify_kinds ~w(avatar cover post_image job_posting_image organization_image)

  ## Gate + lifecycle API (what the storing contexts use)

  @doc "Whether AI image moderation is enabled on this installation."
  def enabled?, do: Application.get_env(:vutuv, :moderate_images, true)

  @doc """
  The moderation state a freshly stored image starts in: `"pending"` (limbo)
  when moderation is enabled, `"approved"` otherwise.
  """
  def initial_state, do: if(enabled?(), do: "pending", else: "approved")

  @doc """
  Whether an asset's moderation state means "released to the world". `nil` is
  released: it marks rows from before this feature existed (grandfathered)
  and asset types that have no stored image yet.
  """
  def released?(nil), do: true
  def released?("approved"), do: true
  def released?(_state), do: false

  @doc """
  Queues (or re-queues) the scan for one asset. `fingerprint` binds the
  verdict to the exact bytes for subjects that can change in place (avatar,
  cover, re-captured screenshots); a re-upload during an open scan lands on
  the open row (partial unique index) and resets it, so the earlier bytes'
  verdict can never release the new bytes. A no-op when moderation is off.
  """
  def enqueue(kind, subject_id, owner_user_id, fingerprint \\ nil) when kind in @kinds do
    if enabled?() do
      now = NaiveDateTime.utc_now(:second)

      result =
        %ImageScan{
          kind: kind,
          subject_id: subject_id,
          owner_user_id: owner_user_id,
          fingerprint: fingerprint
        }
        |> Repo.insert(
          on_conflict: [
            set: [
              status: "pending",
              fingerprint: fingerprint,
              attempts: 0,
              next_attempt_at: nil,
              last_error: nil,
              updated_at: now
            ]
          ],
          conflict_target:
            {:unsafe_fragment, "(kind, subject_id) WHERE status IN ('pending', 'scanning')"}
        )

      ImageScanWorker.nudge()
      result
    else
      :disabled
    end
  end

  ## Draining the queue

  @doc """
  Scans every due job through the model. A no-op when `:moderate_images` is
  off (rows stay `pending`). `opts`: `judge:` injects the per-file verdict
  function (tests stub it; defaults to `Vutuv.Moderation.Ollama.moderate_file/1`),
  `force:` runs even with the flag off, `limit:` caps the batch.
  """
  def deliver_due(opts \\ []) do
    if Keyword.get(opts, :force, false) or enabled?() do
      resume_stuck()
      judge = Keyword.get(opts, :judge, &Ollama.moderate_file/1)
      for scan <- list_due(opts), do: process(scan, judge)
    end

    :ok
  end

  @doc "The due pending scans the next drain would pick up, oldest first."
  def list_due(opts \\ []) do
    now = DateTime.utc_now(:second)

    from(s in ImageScan,
      where:
        s.status == "pending" and
          (is_nil(s.next_attempt_at) or s.next_attempt_at <= ^now),
      order_by: [asc: s.inserted_at],
      limit: ^Keyword.get(opts, :limit, @batch)
    )
    |> Repo.all()
  end

  @doc """
  Re-queues scans a crash left `scanning` for longer than any live inference
  could take. Returns the count reset. Called on worker boot and each poll.
  """
  def resume_stuck do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -@stuck_after_seconds, :second)

    {count, _} =
      from(s in ImageScan, where: s.status == "scanning" and s.updated_at < ^cutoff)
      |> Repo.update_all(set: [status: "pending", updated_at: NaiveDateTime.utc_now(:second)])

    count
  end

  @doc """
  The self-healing backstop: enqueues a scan for every asset stuck in
  `pending` with no open scan row. Covers a crash between a verdict and its
  application, an upload path that forgot to enqueue (the gallery tables
  default to `pending`, so such an image is invisible, never leaked), and
  rows the previous release inserted during a deploy window. Returns the
  number of scans enqueued.
  """
  def repair_drift do
    ImageSubjects.stranded_pending()
    |> Enum.map(fn {kind, subject_id, owner_id, fingerprint} ->
      enqueue(kind, subject_id, owner_id, fingerprint)
    end)
    |> length()
  end

  defp process(%ImageScan{} = scan, judge) do
    case claim(scan, "pending", "scanning") do
      nil ->
        :ok

      scan ->
        case ImageSubjects.source(scan) do
          {:ok, path} -> judge_and_apply(scan, path, judge)
          :gone -> cancel(scan)
        end
    end
  end

  defp judge_and_apply(scan, path, judge) do
    case judge.(path) do
      {:ok, %{safe?: true}} -> approve(scan)
      {:ok, %{safe?: false, category: category}} -> reject(scan, category)
      {:error, {:service, reason}} -> service_retry(scan, reason)
      {:error, {:image, reason}} -> image_retry(scan, reason)
    end
  end

  defp approve(scan) do
    case claim(scan, "scanning", "approved", category: "safe") do
      nil ->
        :ok

      resolved ->
        # :stale means the asset changed under the verdict (re-upload during
        # the scan reset the row; its own scan releases or deletes the new
        # bytes) — the fingerprint-guarded flip refused, so nothing leaked.
        case ImageSubjects.apply_approved(resolved) do
          :ok -> :ok
          :stale -> Logger.info("image scan #{resolved.id}: approve verdict was stale")
        end
    end
  end

  defp reject(scan, category) do
    case claim(scan, "scanning", "rejected", category: category) do
      nil ->
        :ok

      resolved ->
        Logger.info("image scan: rejected #{resolved.kind} #{resolved.subject_id} (#{category})")

        case ImageSubjects.apply_rejected(resolved) do
          :ok -> notify_rejection(resolved)
          :stale -> :ok
        end
    end
  end

  # Member-chosen images get the deletion notice; machine-generated link
  # screenshots silently show no preview (the failed-capture UX).
  defp notify_rejection(%ImageScan{kind: kind} = resolved) when kind in @notify_kinds,
    do: Notifier.image_rejected(resolved)

  defp notify_rejection(_resolved), do: :ok

  defp cancel(scan) do
    case claim(scan, "scanning", "canceled") do
      nil -> :ok
      resolved -> ImageSubjects.cleanup_canceled(resolved)
    end
  end

  # Ollama itself failed — the image is fine. Retry forever at a fixed pace
  # (never counted toward the cap, never auto-resolved): fail-closed limbo
  # until the operator's Ollama is back.
  defp service_retry(scan, reason) do
    Logger.warning(
      "image scan service failure (#{scan.kind} #{scan.subject_id}): " <>
        inspect(reason)
    )

    retry_at = DateTime.add(DateTime.utc_now(:second), @service_retry_seconds)

    update_claimed(scan,
      status: "pending",
      next_attempt_at: retry_at,
      last_error: error_string(reason)
    )

    :ok
  end

  # This particular image cannot be judged. Rare by construction (the store
  # already proved it decodes); at the cap it is rejected — an unverifiable
  # image is never released.
  defp image_retry(scan, reason) do
    attempts = scan.attempts + 1

    if attempts >= @image_error_cap do
      reject(%{scan | attempts: attempts}, "unverifiable")
    else
      retry_at =
        DateTime.add(
          DateTime.utc_now(:second),
          trunc(:math.pow(2, attempts)) * 60
        )

      update_claimed(scan,
        status: "pending",
        attempts: attempts,
        next_attempt_at: retry_at,
        last_error: error_string(reason)
      )

      :ok
    end
  end

  # Atomically moves one scan between statuses, claiming the transition for
  # exactly one caller (the moderation-cases pattern): a concurrent re-upload
  # resets the row to `pending`, so a stale verdict's claim matches zero rows
  # and its side effects never run.
  defp claim(%ImageScan{id: id}, from_status, to_status, extra \\ []) do
    now = NaiveDateTime.utc_now(:second)

    set =
      [status: to_status, updated_at: now]
      |> Keyword.merge(extra)
      |> maybe_stamp_resolution(to_status)

    {_count, rows} =
      from(s in ImageScan, where: s.id == ^id and s.status == ^from_status, select: s)
      |> Repo.update_all(set: set)

    case rows do
      [claimed] -> claimed
      [] -> nil
    end
  end

  defp maybe_stamp_resolution(set, to_status) when to_status in ~w(approved rejected canceled) do
    Keyword.merge(set,
      scanned_at: DateTime.utc_now(:second),
      model: Application.get_env(:vutuv, :ollama_vision_model, "qwen3-vl:8b")
    )
  end

  defp maybe_stamp_resolution(set, _to_status), do: set

  defp update_claimed(%ImageScan{id: id}, set) do
    set = Keyword.put(set, :updated_at, NaiveDateTime.utc_now(:second))

    from(s in ImageScan, where: s.id == ^id and s.status == "scanning")
    |> Repo.update_all(set: set)
  end

  defp error_string(reason), do: reason |> inspect() |> String.slice(0, 255)

  ## Reads

  @doc "One scan by kind + subject (the open one if any, else the latest resolved)."
  def latest_for(kind, subject_id) when kind in @kinds do
    from(s in ImageScan,
      where: s.kind == ^kind and s.subject_id == ^subject_id,
      order_by: [
        asc: fragment("CASE WHEN ? IN ('pending', 'scanning') THEN 0 ELSE 1 END", s.status),
        desc: s.inserted_at
      ],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  This member's rejected scans (newest first) — the DB source the in-app
  notification feed derives "image removed" entries from.
  """
  def rejected_scans_query(user_id) do
    from(s in ImageScan, where: s.owner_user_id == ^user_id and s.status == "rejected")
  end

  @doc "Queue totals for the admin dashboard: %{pending: n, rejected_7d: n}."
  def counts do
    week_ago = DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)

    pending =
      Repo.aggregate(from(s in ImageScan, where: s.status in ^ImageScan.open_statuses()), :count)

    rejected =
      Repo.aggregate(
        from(s in ImageScan, where: s.status == "rejected" and s.scanned_at > ^week_ago),
        :count
      )

    %{pending: pending, rejected_7d: rejected}
  end
end
