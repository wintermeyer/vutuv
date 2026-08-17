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

  Video is not part of this: vutuv stores photos only.
  """

  use VutuvWeb, :controller

  import Ecto.Query, only: [where: 3]

  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
  alias Vutuv.Repo
  alias Vutuv.UUIDv7
  alias VutuvWeb.RateLimit

  @upload_limit 60
  @upload_window :timer.hours(1)

  def create(conn, params), do: upload(conn, params, 200)
  def create_async(conn, params), do: upload(conn, params, 202)

  def show(conn, %{"id" => id}) do
    case own_media(conn, id) do
      %PostImage{} = image ->
        status = if Presenter.media_ready?(image), do: 200, else: 206
        conn |> put_status(status) |> json(Presenter.media_attachment(image))

      nil ->
        not_found(conn)
    end
  end

  def update(conn, %{"id" => id} = params) do
    case own_media(conn, id) do
      %PostImage{} = image ->
        json(conn, Presenter.media_attachment(describe(image, params["description"])))

      nil ->
        not_found(conn)
    end
  end

  defp upload(conn, %{"file" => %Plug.Upload{} = upload} = params, ready_status) do
    with :ok <- within_rate_limit(conn),
         {:ok, image} <- Posts.create_pending_image(conn.assigns.current_user, upload) do
      image = describe(image, params["description"])
      status = if Presenter.media_ready?(image), do: 200, else: ready_status

      conn |> put_status(status) |> json(Presenter.media_attachment(image))
    else
      {:error, :rate_limited} ->
        conn |> put_status(429) |> json(%{error: "Too many uploads"})

      {:error, :too_large} ->
        conn
        |> put_status(413)
        |> json(%{error: "File exceeds #{Posts.max_image_filesize()} bytes"})

      {:error, _invalid} ->
        validation_error(conn, "Send a JPEG, PNG or WebP image in the \"file\" field.")
    end
  end

  defp upload(conn, _params, _ready_status),
    do: validation_error(conn, "Send multipart/form-data with the file in the \"file\" field.")

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
    end
  end

  defp describe(image, description) when is_binary(description) and description != "" do
    case Posts.update_image_alt(image, description) do
      {:ok, updated} -> updated
      {:error, _changeset} -> image
    end
  end

  defp describe(image, _none), do: image

  defp within_rate_limit(conn) do
    case RateLimit.check(conn, :mastodon_media_upload, nil,
           limit: @upload_limit,
           window_ms: @upload_window
         ) do
      :ok -> :ok
      :rate_limited -> {:error, :rate_limited}
    end
  end

  defp validation_error(conn, message) do
    conn |> put_status(422) |> json(%{error: "Validation failed: " <> message})
  end

  defp not_found(conn), do: conn |> put_status(404) |> json(%{error: "Record not found"})
end
