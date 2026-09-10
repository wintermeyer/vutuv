defmodule Vutuv.MediaJobWritersTest do
  @moduledoc """
  That the three pipelines actually write into the media-job log (issue #2103).

  This is the file the feature cannot do without. `Vutuv.MediaJobs` swallows
  every error by design — a log write must not be able to take a video
  conversion down with it — so a call site that stops working (a renamed kind,
  a branch that grew a new outcome, a foreign key that started refusing) is
  **silent in production and green in every other test**. Each test here drives
  the real pipeline through its own stub seam and asserts a row appeared with
  the right kind and outcome.

  A refusal is deliberately asserted as a *finished* job, not a failed one: the
  pipeline did its work and the answer was no.
  """
  # Not async: the image-scan case flips :moderate_images and :uploads_dir_prefix.
  use Vutuv.DataCase, async: false

  import Ecto.Query
  import Vutuv.PostsHelpers

  alias Vutuv.Accounts
  alias Vutuv.MediaJobs.MediaJob
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Posts.PostVideo
  alias Vutuv.Posts.Screenshots
  alias Vutuv.Repo
  alias Vutuv.Videos.Job

  defp jobs(kind), do: Repo.all(from(j in MediaJob, where: j.kind == ^kind, order_by: j.id))

  describe "the AI image scan" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "vutuv_media_job_scan_#{System.unique_integer([:positive])}")

      prev_dir = Application.fetch_env(:vutuv, :uploads_dir_prefix)
      Application.put_env(:vutuv, :uploads_dir_prefix, tmp)
      Application.put_env(:vutuv, :moderate_images, true)

      on_exit(fn ->
        File.rm_rf(tmp)
        Application.put_env(:vutuv, :moderate_images, false)

        case prev_dir do
          {:ok, was} -> Application.put_env(:vutuv, :uploads_dir_prefix, was)
          :error -> Application.delete_env(:vutuv, :uploads_dir_prefix)
        end
      end)

      user = insert(:activated_user)
      {:ok, user} = Accounts.update_user(user, %{avatar: jpeg_upload()})
      %{user: user}
    end

    # One real stored picture, so the scan has a file to hand the judge; without
    # it `ImageSubjects.source/1` answers `:gone` and the scan is cancelled
    # before any model call, which is precisely the branch that must NOT log.
    defp jpeg_upload do
      src =
        Path.join(System.tmp_dir!(), "media_job_src_#{System.unique_integer([:positive])}.jpg")

      {:ok, img} = Image.new(120, 90, color: [10, 120, 200])
      {:ok, _} = Image.write(img, src)
      on_exit(fn -> File.rm(src) end)
      %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
    end

    test "a safe verdict is a finished job naming the member", %{user: user} do
      ImageScans.deliver_due(judge: fn _path -> {:ok, %{safe?: true, category: "safe"}} end)

      assert [job] = jobs("image_scan")
      assert job.status == "done"
      assert job.detail == "safe"
      assert job.user_id == user.id
      assert job.subject_type == "image_scan"
      assert job.finished_at
    end

    test "a refusal is a finished job that says what it refused, not a failure" do
      ImageScans.deliver_due(judge: fn _path -> {:ok, %{safe?: false, category: "nudity"}} end)

      assert [job] = jobs("image_scan")
      assert job.status == "done"
      assert job.detail == "rejected: nudity"
    end

    test "a scanner that cannot be reached is a failed job" do
      ImageScans.deliver_due(judge: fn _path -> {:error, {:service, :econnrefused}} end)

      assert [job] = jobs("image_scan")
      assert job.status == "failed"
      assert job.detail =~ "econnrefused"
    end
  end

  describe "the screenshot capture" do
    setup do
      post = create_post!(insert(:activated_user), %{body: "Look: https://example.com/page"})
      {:ok, _job} = Screenshots.reconcile(post)
      %{post: post}
    end

    test "a capture that works is a finished job pointing at the post", %{post: post} do
      Screenshots.deliver_due(
        force: true,
        capture: fn _job -> {:ok, %{screenshot: "0123456789ab.avif", width: 400, height: 264}} end
      )

      assert [job] = jobs("screenshot")
      assert job.status == "done"
      assert job.detail == "captured"
      assert job.post_id == post.id
      assert job.user_id == post.user_id
    end

    test "a capture that fails is a failed job carrying the reason" do
      Screenshots.deliver_due(force: true, capture: fn _job -> {:error, :timeout} end)

      assert [job] = jobs("screenshot")
      assert job.status == "failed"
      assert job.detail =~ "timeout"
    end
  end

  describe "the video conversion" do
    test "a clip whose original is gone is a failed job naming the member" do
      user = insert(:activated_user)

      video =
        Repo.insert!(%PostVideo{
          user_id: user.id,
          token: "mediajobtest#{System.unique_integer([:positive])}",
          content_type: "video/mp4",
          size_bytes: 1_000,
          stage: "queued"
        })

      :ok = Job.run(video.id)

      assert [job] = jobs("video_conversion")
      assert job.status == "failed"
      assert job.detail =~ "probe"
      assert job.user_id == user.id
      assert job.subject_id == video.id
      assert job.subject_type == "post_video"
    end
  end
end
