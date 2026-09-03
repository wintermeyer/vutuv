defmodule VutuvWeb.ApiV2.VideoController do
  @moduledoc """
  Post video upload over the API (issue #1915): `POST /api/2.0/me/post_videos`
  (multipart, the file in the `video` field, optional `alt`) keeps the clip
  and starts the pipeline, answering **202** with its state; `GET
  /api/2.0/me/post_videos/:id` says where it is (`ready: true` once the H.264
  file and the AI check are through), and its `id` then goes into `video_id`
  of `POST /posts` — a post naming a clip that is not ready yet is refused,
  the way the Mastodon API refuses one. Unattached uploads are swept after a
  day, or deleted explicitly via `DELETE`. Same store, pipeline and audience
  proxy as the composer's uploads (`Vutuv.Videos`).
  """

  use VutuvWeb, :controller

  alias Vutuv.Posts.PostVideo
  alias Vutuv.Videos
  alias VutuvWeb.ApiV2
  alias VutuvWeb.ApiV2.Problem

  def create(conn, %{"video" => %Plug.Upload{} = upload} = params) do
    user = conn.assigns.current_user

    case Videos.create_pending_video(user, upload.path, upload.filename) do
      {:ok, video} ->
        ApiV2.send_json(conn, video_doc(set_alt(video, params["alt"])), 202)

      {:error, :too_large} ->
        Problem.send_problem(conn, 413, "File too large",
          detail: "Videos may have at most #{Videos.max_filesize()} bytes."
        )

      {:error, :too_long} ->
        Problem.send_problem(conn, 422, "Video too long",
          detail: "Videos may be at most #{Videos.max_duration_seconds()} seconds long."
        )

      {:error, :disabled} ->
        Problem.send_problem(conn, 422, "Videos are not accepted",
          detail: "This installation does not take videos from this account."
        )

      {:error, _invalid} ->
        Problem.send_problem(conn, 422, "Invalid video",
          detail: "Send an MP4, MOV or WebM file in the \"video\" field."
        )
    end
  end

  def create(conn, _params) do
    Problem.send_problem(conn, 400, "Bad request",
      detail: ~s(Send multipart/form-data with the file in the "video" field.)
    )
  end

  def show(conn, %{"id" => id}) do
    case Videos.pending_video(conn.assigns.current_user, id) do
      %PostVideo{} = video -> ApiV2.send_json(conn, video_doc(video))
      nil -> Problem.not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    case Videos.pending_video(conn.assigns.current_user, id) do
      %PostVideo{} = video ->
        Videos.delete_pending_video(video)
        send_resp(conn, 204, "")

      # An attached clip belongs to its post (delete the post instead).
      nil ->
        Problem.not_found(conn)
    end
  end

  defp set_alt(video, alt) when is_binary(alt) and alt != "" do
    case Videos.update_alt(video, alt) do
      {:ok, video} -> video
      {:error, _changeset} -> video
    end
  end

  defp set_alt(video, _none), do: video

  defp video_doc(%PostVideo{} = video) do
    %{
      type: "post_video",
      id: video.id,
      alt: video.alt,
      width: video.width,
      height: video.height,
      duration_seconds: PostVideo.seconds(video),
      content_type: video.content_type,
      # Where the pipeline is; `ready` is the one flag a client needs.
      stage: video.stage,
      progress: video.progress,
      ready: PostVideo.ready?(video),
      refused: PostVideo.refused?(video),
      # The composer sweep applies to API uploads too.
      attach_within_hours: Videos.pending_max_age_hours()
    }
  end
end
