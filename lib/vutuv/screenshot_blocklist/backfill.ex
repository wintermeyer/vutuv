defmodule Vutuv.ScreenshotBlocklist.Backfill do
  @moduledoc """
  Judges the captures this installation **already** stores, so the page check
  is not a rule that only applies to links posted from today on.

  Every stored capture is a picture somebody sees beside a post or on a
  profile, and the ones taken before the check existed include consent walls
  nobody ever noticed. Rather than shooting all of them again — Chromium per
  host, for a picture that is already on disk — this reads the stored thumb and
  asks the model about that. (Measured: the stored 400x264 thumbs are judged
  correctly, and the offenders found in them were real.)

  All three queues are the source, because a wall does not care which of them
  met it: post link screenshots (`Vutuv.Posts.PostScreenshot`), profile links
  (`Vutuv.Profiles.Url`) and organization homepages
  (`Vutuv.Organizations.OrganizationScreenshot`). A site that only ever
  appeared as somebody's profile link would otherwise never be looked at — and
  nothing re-captures a link whose URL has not changed, so its picture would
  stay wrong forever.

  One host is judged once. The work is therefore per *host*, not per capture:
  2,026 stored post captures on this installation come from 374 hosts, more
  than half of them from one site, so a per-capture backfill would ask the same
  question a thousand times. The **newest** capture of a host is the one that
  gets judged — a re-check is meant to see how the site looks now.

  ## The clock

  A host leaves the due list on **every** outcome:

    * `usable` / `blocked` — a verdict, stored, and the host is done until the
      re-check age (`Vutuv.ScreenshotBlocklist.recheck_after_days/0`).
    * `unknown` — the picture could not be decoded, or the answer was not a
      verdict, or the ballot did not confirm a suspicion. Stored too, with a
      short retry age: whatever is wrong here will not fix itself in two
      minutes, and a host that cannot be judged must not hold the front of an
      oldest-first queue forever.

  The one outcome that stamps nothing is Ollama being **unreachable**, which is
  not the host's fault and would otherwise mark every site on the installation
  as unjudgeable during a restart. A service failure ends the whole pass; the
  next one starts where this began.
  """

  import Ecto.Query

  alias Vutuv.Organizations.OrganizationScreenshot
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Profiles.Url
  alias Vutuv.Repo
  alias Vutuv.Screenshot
  alias Vutuv.ScreenshotBlocklist
  alias Vutuv.ScreenshotBlocklist.Check
  alias Vutuv.ScreenshotBlocklist.Vision

  require Logger

  # Hosts per pass. Each one costs an inference (three when the answer is
  # "blocked"), so a pass is minutes, not seconds.
  @batch 10

  @doc """
  Judges up to `limit` unjudged hosts from the stored captures. Returns
  `%{checked: n, blocked: n, unknown: n}`.
  """
  def check_due(opts \\ []) do
    limit = Keyword.get(opts, :limit, @batch)
    decide = Keyword.get(opts, :decide, &Vision.decide/1)

    limit
    |> due_hosts()
    |> Enum.reduce_while(%{checked: 0, blocked: 0, unknown: 0}, fn candidate, tally ->
      case judge(candidate, decide) do
        {:ok, :blocked} ->
          {:cont, %{tally | checked: tally.checked + 1, blocked: tally.blocked + 1}}

        {:ok, :usable} ->
          {:cont, %{tally | checked: tally.checked + 1}}

        {:ok, :unknown} ->
          {:cont, %{tally | unknown: tally.unknown + 1}}

        :service_down ->
          {:halt, tally}
      end
    end)
  end

  @doc """
  The hosts a pass would look at: `{host, capture}` for every host without a
  verdict young enough to stand. Public so a test and an admin page can see the
  same list the sweeper works from.
  """
  def due_hosts(limit \\ @batch) do
    checks = Map.new(Repo.all(Check), &{&1.host, &1})

    newest_per_host()
    |> Enum.map(fn capture -> {ScreenshotBlocklist.host_of(capture.url), capture} end)
    |> Enum.reject(fn {host, _capture} -> is_nil(host) end)
    |> Enum.uniq_by(fn {host, _capture} -> host end)
    |> Enum.reject(fn {host, _capture} -> ScreenshotBlocklist.fresh?(Map.get(checks, host)) end)
    |> Enum.take(limit)
  end

  # The newest stored capture per URL host, across the three queues. The host
  # is extracted in SQL so a growing table does not have to be read into memory
  # to find the handful of sites that were never judged; `www.` and the rest of
  # the normalisation happen in `host_of/1` afterwards.
  defp newest_per_host do
    post_captures() ++ link_captures() ++ organization_captures()
  end

  defp post_captures do
    from(ps in PostScreenshot,
      where: ps.status == "ready" and not is_nil(ps.screenshot),
      distinct: fragment("split_part(split_part(?, '//', 2), '/', 1)", ps.url),
      order_by: [
        asc: fragment("split_part(split_part(?, '//', 2), '/', 1)", ps.url),
        desc: ps.inserted_at
      ],
      select: %{id: ps.id, url: ps.url, screenshot: ps.screenshot}
    )
    |> Repo.all()
  end

  defp link_captures do
    from(u in Url,
      where: not is_nil(u.screenshot),
      distinct: fragment("split_part(split_part(?, '//', 2), '/', 1)", u.value),
      order_by: [
        asc: fragment("split_part(split_part(?, '//', 2), '/', 1)", u.value),
        desc: u.inserted_at
      ],
      select: %{id: u.id, url: u.value, screenshot: u.screenshot}
    )
    |> Repo.all()
  end

  defp organization_captures do
    from(os in OrganizationScreenshot,
      where: os.status == "ready" and not is_nil(os.screenshot),
      distinct: fragment("split_part(split_part(?, '//', 2), '/', 1)", os.url),
      order_by: [
        asc: fragment("split_part(split_part(?, '//', 2), '/', 1)", os.url),
        desc: os.inserted_at
      ],
      select: %{id: os.id, url: os.url, screenshot: os.screenshot}
    )
    |> Repo.all()
  end

  defp judge({host, capture}, decide) do
    case Screenshot.stored_thumb_path(capture) do
      nil ->
        record_unknown(host, capture.url, "the stored capture file is missing")
        {:ok, :unknown}

      path ->
        apply_decision(host, capture, path, decide.(path))
    end
  end

  defp apply_decision(host, capture, _path, {:usable, verdict}) do
    ScreenshotBlocklist.record_verdict(host, capture.url, "usable", verdict)
    {:ok, :usable}
  end

  defp apply_decision(host, capture, path, {:block, verdict}) do
    ScreenshotBlocklist.block_host(host, capture.url, verdict, path)
    Logger.info("screenshot blocklist: #{host} added by backfill (#{verdict.obstruction})")
    {:ok, :blocked}
  end

  defp apply_decision(host, capture, _path, {:discard, verdict}) do
    # An error or blank page says nothing about the site, only about that one
    # capture; an outvoted suspicion says nothing yet. Both leave the host to be
    # looked at again with a fresh picture.
    ScreenshotBlocklist.record_verdict(host, capture.url, "unknown", verdict)
    {:ok, :unknown}
  end

  defp apply_decision(_host, _capture, _path, {:error, {:service, reason}}) do
    Logger.info("screenshot blocklist backfill stopped: Ollama unreachable (#{inspect(reason)})")
    :service_down
  end

  defp apply_decision(host, capture, _path, {:error, reason}) do
    record_unknown(host, capture.url, "no verdict: #{inspect(reason)}")
    {:ok, :unknown}
  end

  defp record_unknown(host, url, reason) do
    ScreenshotBlocklist.record_verdict(host, url, "unknown", %{reason: reason})
  end
end
