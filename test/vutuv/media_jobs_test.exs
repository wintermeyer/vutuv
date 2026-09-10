defmodule Vutuv.MediaJobsTest do
  @moduledoc """
  The media-job log (issue #2103): the plain table the media pipelines write a
  row into and never read back.

  Three shapes carry most of the weight here. **Best-effort writing** — every
  function answers rather than raising, because a log write must never take the
  work it is recording down with it, and the callers are fire-and-forget tasks
  that can die between `start/2` and `finish/2`. The **nullable member** — a
  screenshot of a remote post belongs to nobody, so sorting by member must not
  quietly drop those rows the way an inner join would. And the **duration
  sort**, which has to count a still-running job's elapsed time, or "longest
  first" would file every stuck job under "unknown" and push exactly the rows
  the page exists for onto the last page.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias Vutuv.MediaJobs
  alias Vutuv.MediaJobs.MediaJob
  alias Vutuv.Repo

  defp reload(%MediaJob{id: id}), do: Repo.get!(MediaJob, id)

  defp backdate!(job, seconds) do
    job
    |> Ecto.Changeset.change(%{started_at: DateTime.add(DateTime.utc_now(), -seconds, :second)})
    |> Repo.update!()
  end

  describe "start/2" do
    test "records a running job and answers it" do
      user = insert(:user)
      post = insert(:post, user: user)

      job =
        MediaJobs.start("image_scan",
          subject_type: "image_scan",
          subject_id: Vutuv.UUIDv7.generate(),
          user_id: user.id,
          post_id: post.id
        )

      assert %MediaJob{} = job

      stored = reload(job)
      assert stored.kind == "image_scan"
      assert stored.status == "running"
      assert stored.user_id == user.id
      assert stored.post_id == post.id
      assert stored.started_at
      refute stored.finished_at
    end

    test "an unowned job is fine — a remote post's screenshot belongs to nobody" do
      job = MediaJobs.start("screenshot")

      refute reload(job).user_id
      refute reload(job).post_id
    end

    test "an undeclared kind is refused rather than logged" do
      refute MediaJobs.start("not_a_kind")
    end
  end

  describe "finish/2 and fail/2" do
    test "finish stamps the end and the outcome" do
      job = MediaJobs.start("screenshot")

      assert :ok = MediaJobs.finish(job, detail: "ready")

      stored = reload(job)
      assert stored.status == "done"
      assert stored.detail == "ready"
      assert stored.finished_at
      assert MediaJobs.elapsed_ms(stored) >= 0
    end

    test "fail records the reason as text, whatever shape it arrives in" do
      job = MediaJobs.start("video_conversion")

      assert :ok = MediaJobs.fail(job, {:h264, :timeout})

      stored = reload(job)
      assert stored.status == "failed"
      assert stored.detail =~ "h264"
      assert stored.finished_at
    end

    test "an over-long reason is cut to fit its column instead of raising" do
      job = MediaJobs.start("video_conversion")

      assert :ok = MediaJobs.fail(job, String.duplicate("x", 5_000))

      assert String.length(reload(job).detail) <= 255
    end

    test "closing a job that was never started is a no-op, not a crash" do
      assert :ok = MediaJobs.finish(nil)
      assert :ok = MediaJobs.fail(nil, :whatever)
    end

    test "a second close cannot move a stamp that already means something" do
      job = MediaJobs.start("screenshot")
      :ok = MediaJobs.finish(job, detail: "captured")
      first = reload(job)

      :ok = MediaJobs.fail(job, :too_late)

      assert reload(job).status == "done"
      assert reload(job).detail == "captured"
      assert reload(job).finished_at == first.finished_at
    end

    test "a job left running stays running — that is what the page is for" do
      job = MediaJobs.start("image_scan")

      assert reload(job).status == "running"
      assert MediaJobs.elapsed_ms(reload(job)) >= 0
    end

    test "elapsed time counts from the start while a job runs" do
      job = MediaJobs.start("image_scan") |> backdate!(7_200)

      assert MediaJobs.elapsed_ms(job) >= 7_200_000
    end
  end

  describe "page/3 and count/1" do
    setup do
      anna = insert(:user, username: "media-anna")
      bert = insert(:user, username: "media-bert")

      scan = MediaJobs.start("image_scan", user_id: anna.id)
      :ok = MediaJobs.finish(scan, detail: "safe")

      video = MediaJobs.start("video_conversion", user_id: bert.id)
      :ok = MediaJobs.fail(video, :probe_failed)

      shot = MediaJobs.start("screenshot")

      %{anna: anna, bert: bert, scan: scan.id, video: video.id, shot: shot.id}
    end

    defp ids(filters), do: filters |> MediaJobs.page() |> Enum.map(& &1.id)

    test "lists every job, newest first", %{scan: scan, video: video, shot: shot} do
      assert [^shot, ^video, ^scan] = ids(MediaJobs.filters(%{}))
      assert MediaJobs.count(MediaJobs.filters(%{})) == 3
    end

    test "search matches the member", %{scan: scan} do
      assert [^scan] = ids(MediaJobs.filters(%{"q" => "media-anna"}))
    end

    test "search matches the kind", %{video: video} do
      assert [^video] = ids(MediaJobs.filters(%{"q" => "video_conv"}))
    end

    test "search matches the outcome", %{video: video} do
      assert [^video] = ids(MediaJobs.filters(%{"q" => "probe_failed"}))
    end

    test "sorting by member keeps the jobs that have none", %{shot: shot} do
      found = ids(MediaJobs.filters(%{"sort" => "member", "dir" => "asc"}))

      assert length(found) == 3
      assert shot in found
    end

    test "longest-first puts a job that has been running for hours at the top", %{shot: shot} do
      # The page's whole reason for existing: a step that has not come back is
      # the longest-running one, so it has to be the first row under "Took ▼",
      # not filed under an unknown duration on the last page. Calibrated: with
      # the sort reading a stored end stamp instead of the elapsed time, this
      # row lands last.
      shot |> then(&Repo.get!(MediaJob, &1)) |> backdate!(10_800)

      assert [^shot | _] = ids(MediaJobs.filters(%{"sort" => "duration", "dir" => "desc"}))
    end

    test "shortest-first puts that same job at the bottom", %{shot: shot} do
      shot |> then(&Repo.get!(MediaJob, &1)) |> backdate!(10_800)

      assert List.last(ids(MediaJobs.filters(%{"sort" => "duration", "dir" => "asc"}))) == shot
    end

    test "an invented sort or direction falls back to the default" do
      filters = MediaJobs.filters(%{"sort" => "; drop table", "dir" => "sideways"})

      assert filters.sort == "started"
      assert filters.dir == "desc"
    end

    test "the member is preloaded for the table", %{anna: anna} do
      assert [_, _, job] = MediaJobs.page(MediaJobs.filters(%{}))
      assert job.user.username == anna.username
    end
  end

  describe "delete_expired/0" do
    test "drops rows past the retention window and keeps the rest" do
      fresh = MediaJobs.start("screenshot")
      old = MediaJobs.start("screenshot")

      backdate!(old, (MediaJobs.retention_days() + 1) * 86_400)

      assert MediaJobs.delete_expired() == 1
      assert Repo.get(MediaJob, fresh.id)
      refute Repo.get(MediaJob, old.id)
    end
  end
end
