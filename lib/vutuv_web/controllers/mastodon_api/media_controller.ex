defmodule VutuvWeb.MastodonApi.MediaController do
  @moduledoc """
  Mastodon's media endpoints, mapped onto vutuv's pending post images.

  The two-step shape Mastodon clients already speak — upload here, then name
  the returned ids in `media_ids[]` on `POST /api/v1/statuses` — is exactly the
  composer's eager upload, so an unattached `Vutuv.Posts.PostImage` row *is* the
  Mastodon attachment. Nothing about the store, the sweeper that removes
  unattached leftovers after a day, or the audience proxy differs from a photo
  added on the website.

  **The AI image scan is why `/api/v2/media` exists here.** A fresh upload is
  `pending` and its post stays owner-only until every picture is released
  (`Vutuv.Posts.moderation_hidden?/1`), which the website renders as the amber
  "only you can see this so far" panel. A phone client has nowhere to put that,
  so instead of publishing into limbo we use the state Mastodon already
  defines: v2 answers **202** with a `url` of `null`, the client polls
  `GET /api/v1/media/:id` (**206** while it waits, **200** once ready) and posts
  when the picture is through. v1 keeps its synchronous **200**, because older
  clients do not poll — such a post simply behaves like its website twin and
  appears for everybody once the scan finishes.

  **A video takes the same two steps** (issue #1915), on a longer clock: the
  upload lands as a `Vutuv.Posts.PostVideo`, the pipeline converts and checks
  it for about a minute, and both v1 and v2 answer **202** with a `url` of
  `null` — a video is never ready synchronously, whatever v1 promises for a
  picture. `GET /api/v1/media/:id` answers **206** until it is, and a status
  naming an unfinished clip is refused with **422** the way Mastodon refuses
  one ("Cannot attach files that have not finished processing").
  """

  use VutuvWeb, :controller

  import VutuvWeb.MastodonApi.Errors

  import Ecto.Query, only: [where: 3]

  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostVideo
  alias Vutuv.Repo
  alias Vutuv.UUIDv7
  alias Vutuv.Videos
  alias VutuvWeb.RateLimit

  @upload_limit 60
  @upload_window :timer.hours(1)

  def create(conn, params), do: upload(conn, params, 200)
  def create_async(conn, params), do: upload(conn, params, 202)

  def show(conn, %{"id" => id}) do
    case own_media(conn, id) do
      nil ->
        not_found(conn)

      media ->
        status = if Presenter.media_ready?(media), do: 200, else: 206

        conn
        |> put_status(status)
        |> json(Presenter.media_attachment(media, conn.assigns.current_user))
    end
  end

  def update(conn, %{"id" => id} = params) do
    case own_media(conn, id) do
      nil ->
        not_found(conn)

      media ->
        json(
          conn,
          Presenter.media_attachment(
            describe(media, params["description"]),
            conn.assigns.current_user
          )
        )
    end
  end

  @doc """
  Throws away an upload that was never posted (`DELETE /api/v1/media/:id`).

  One of the two methods Mastodon's **API version 4** stands for, and the half a
  composer needs: a client uploads eagerly, so every picture a member picks and
  then changes their mind about is already on this server. Without this the file
  sat there until the next day's sweep of unattached leftovers
  (`Vutuv.Posts.PendingImageSweeper`) — which is a promise vutuv keeps, but not
  the one a member makes when they tap the ✕ on a photo.

  Only an **unattached** upload of the member's own, like every other method
  here: once a picture belongs to a post it is removed through the status, not
  behind its back. Mastodon answers 200 with an empty body, and a client reads
  the status rather than the payload.
  """
  def delete(conn, %{"id" => id}) do
    case own_media(conn, id) do
      %PostImage{} = image ->
        :ok = Posts.delete_pending_image(image)
        json(conn, %{})

      %PostVideo{} = video ->
        :ok = Videos.delete_pending_video(video)
        json(conn, %{})

      nil ->
        not_found(conn)
    end
  end

  defp upload(conn, %{"file" => %Plug.Upload{} = upload} = params, ready_status) do
    with :ok <- within_rate_limit(conn),
         {:ok, media} <- store(conn.assigns.current_user, upload) do
      media = describe(media, params["description"])
      status = if Presenter.media_ready?(media), do: 200, else: ready_status(media, ready_status)

      conn
      |> put_status(status)
      |> json(Presenter.media_attachment(media, conn.assigns.current_user))
    else
      {:error, :rate_limited} ->
        error(conn, 429, "Too many uploads")

      {:error, :too_large} ->
        error(conn, 413, "File exceeds #{Posts.max_image_filesize()} bytes")

      {:error, :video_too_large} ->
        error(conn, 413, "Video exceeds #{Videos.max_filesize()} bytes")

      {:error, :too_long} ->
        validation_error(conn, "Videos may be at most #{Videos.max_duration_seconds()} seconds long.")

      {:error, _invalid} ->
        validation_error(conn, "Send #{accepted_types()} in the \"file\" field.")
    end
  end

  defp upload(conn, _params, _ready_status),
    do: validation_error(conn, "Send multipart/form-data with the file in the \"file\" field.")

  # A clip is never ready when the upload answers, on v1 as on v2.
  defp ready_status(%PostVideo{}, _requested), do: 202
  defp ready_status(_image, requested), do: requested

  # By extension, the way the two stores decide it: a clip goes to the video
  # pipeline, anything else is tried as a picture.
  defp store(user, %Plug.Upload{filename: filename} = upload) do
    if Vutuv.Uploads.valid_extension?(filename, Videos.extension_whitelist()) do
      case Videos.create_pending_video(user, upload.path, filename) do
        {:error, :too_large} -> {:error, :video_too_large}
        other -> other
      end
    else
      Posts.create_pending_image(user, upload)
    end
  end

  # Named from the uploader's own whitelist rather than typed out here. The
  # fixed sentence said "a JPEG, PNG or WebP image" whatever the installation
  # could really take, so an installation whose libvips decodes HEIC refused to
  # admit it — and this is the message a member reads after the upload has
  # already gone up, so it is the one place the answer has to be exact. What
  # this endpoint accepts is also what `/api/v2/instance` advertises
  # (`supported_mime_types`), which is where a client looks before it converts
  # a picture out of the phone's photo library at all.
  defp accepted_types do
    images =
      Vutuv.PostImageStore.extension_whitelist()
      |> Enum.map(&(&1 |> String.trim_leading(".") |> String.upcase()))
      |> Enum.uniq()
      |> Enum.join(", ")

    if Videos.enabled?() do
      videos =
        Videos.extension_whitelist()
        |> Enum.map_join(", ", &(&1 |> String.trim_leading(".") |> String.upcase()))

      "an image (#{images}) or a video (#{videos})"
    else
      "an image (#{images})"
    end
  end

  # Only the member's own, still-unattached uploads. An attached picture belongs
  # to its post from then on and is edited or removed through the status.
  #
  # Written as a query with `is_nil/1` rather than `Repo.get_by(post_id: nil)`,
  # which Ecto refuses outright — the same nil-comparison trap that made
  # attaching a photo to an organization post raise.
  defp own_media(conn, id) do
    with uuid when is_binary(uuid) <- UUIDv7.cast_or_nil(id) do
      user_id = conn.assigns.current_user.id

      PostImage
      |> where([i], i.id == ^uuid and i.user_id == ^user_id and is_nil(i.post_id))
      |> Repo.one()
      |> Kernel.||(
        PostVideo
        |> where([v], v.id == ^uuid and v.user_id == ^user_id and is_nil(v.post_id))
        |> Repo.one()
      )
    end
  end

  defp describe(%PostVideo{} = video, description)
       when is_binary(description) and description != "" do
    case Videos.update_alt(video, description) do
      {:ok, updated} -> updated
      {:error, _changeset} -> video
    end
  end

  defp describe(%PostImage{} = image, description)
       when is_binary(description) and description != "" do
    case Posts.update_image_alt(image, description) do
      {:ok, updated} -> updated
      {:error, _changeset} -> image
    end
  end

  defp describe(media, _none), do: media

  defp within_rate_limit(conn) do
    case RateLimit.check(conn, :mastodon_media_upload, nil,
           limit: @upload_limit,
           window_ms: @upload_window
         ) do
      :ok -> :ok
      :rate_limited -> {:error, :rate_limited}
    end
  end
end
