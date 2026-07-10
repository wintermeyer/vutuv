defmodule Vutuv.Moderation.EvidenceScreenshot do
  @moduledoc """
  The evidence screenshot a report captures at report time, before the owner
  can clean anything up:

    * a **profile** case shoots the public profile page,
    * a **message** case shoots the conversation context rendered by the
      token-guarded `/moderation/evidence/:token` page (the thread is private,
      so headless Chromium cannot log in - the short-lived signed token is
      its key),
    * **post** cases keep their text snapshot (no capture).

  Headless Chromium only shoots the viewport, so "full page" is done by
  opening a very tall window (#{6_000}px) and trimming the uniform canvas
  below the content with libvips. Caveat: the app layout's sticky footer
  rides at the window bottom, so profile shots keep their empty stretch in
  the middle - the full content is always on the image, the admin page shows
  it in a scrollbox. The standalone message-evidence page has no such footer
  and trims cleanly. The file lands in the private
  `<uploads_dir_prefix>/moderation_evidence/` tree (never served statically;
  admins get it through the authorizing
  `/admin/moderation/:id/evidence` route) and is purged with the owner's
  account (`Vutuv.Accounts.delete_user/1`).

  Captures run async (`async_capture/1`) and are disabled in tests via
  `config :vutuv, :capture_report_evidence`.
  """

  require Logger

  alias Vutuv.Moderation.Case
  alias Vutuv.Repo

  @token_salt "moderation evidence"
  @token_max_age 600
  @window {1280, 6_000}

  @doc "Captures in the background; a no-op when disabled or not capturable."
  def async_capture(%Case{} = case_record) do
    if Application.get_env(:vutuv, :capture_report_evidence, true) and
         evidence_url(case_record) != nil do
      {:ok, _pid} =
        Task.Supervisor.start_child(Vutuv.TaskSupervisor, fn -> capture(case_record) end)
    end

    :ok
  end

  @doc "The page to shoot for this case, or nil when text evidence suffices."
  def evidence_url(%Case{content_type: "user"} = case_record) do
    case Repo.get(Vutuv.Accounts.User, case_record.owner_id) do
      nil -> nil
      owner -> VutuvWeb.Endpoint.url() <> "/#{owner.username}"
    end
  end

  def evidence_url(%Case{content_type: "message"} = case_record) do
    VutuvWeb.Endpoint.url() <> "/moderation/evidence/" <> sign_token(case_record.id)
  end

  def evidence_url(%Case{content_type: "company"} = case_record) do
    case Repo.get(Vutuv.Companies.Company, case_record.content_id) do
      nil -> nil
      company -> VutuvWeb.Endpoint.url() <> "/companies/#{company.slug}"
    end
  end

  def evidence_url(_case_record), do: nil

  @doc "Signs the short-lived token that lets Chromium see the evidence page."
  def sign_token(case_id),
    do: Phoenix.Token.sign(VutuvWeb.Endpoint, @token_salt, case_id)

  @doc "The case id behind an evidence token, or :error (bad or expired)."
  def verify_token(token),
    do: Phoenix.Token.verify(VutuvWeb.Endpoint, @token_salt, token, max_age: @token_max_age)

  @doc "The absolute path of the stored screenshot file for `filename`."
  def path(filename),
    do: Path.join(Vutuv.Uploads.disk_dir("moderation_evidence"), filename)

  @doc "Removes the evidence files of the given cases (account deletion)."
  def delete_for_cases(case_ids) do
    for id <- case_ids, do: File.rm(path("#{id}.webp"))
    :ok
  end

  @doc """
  Synchronous capture + store; safe to run unsupervised (logs, never raises).
  """
  def capture(%Case{} = case_record) do
    with url when is_binary(url) <- evidence_url(case_record),
         raw = Path.join(System.tmp_dir!(), "evidence-#{case_record.id}.png"),
         :ok <- Vutuv.PageScreenshot.capture(url, raw, window: @window),
         {:ok, filename} <- trim_and_store(raw, case_record.id) do
      File.rm(raw)
      store_filename(case_record, filename)
      :ok
    else
      nil ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "evidence screenshot failed for case #{case_record.id}: #{inspect(reason)}"
        )

        :error
    end
  end

  # The tall capture ends in kilometers of empty canvas; trim it away so the
  # stored file is exactly the page. A trim failure (e.g. an all-uniform
  # image) falls back to the untrimmed capture - better too much evidence
  # than none.
  defp trim_and_store(raw_path, case_id) do
    filename = "#{case_id}.webp"
    dest = path(filename)
    File.mkdir_p!(Path.dirname(dest))

    with {:ok, image} <- Image.open(raw_path),
         {:ok, trimmed} <- trim(image),
         {:ok, _} <- Image.write(trimmed, dest) do
      {:ok, filename}
    end
  end

  defp trim(image) do
    case Image.trim(image) do
      {:ok, trimmed} -> {:ok, trimmed}
      {:error, _} -> {:ok, image}
    end
  end

  defp store_filename(case_record, filename) do
    case_record
    |> Ecto.Changeset.change(evidence_screenshot: filename)
    |> Repo.update!()

    Repo.insert!(%Vutuv.Moderation.Event{
      case_id: case_record.id,
      action: "evidence_captured"
    })

    :ok
  end
end
