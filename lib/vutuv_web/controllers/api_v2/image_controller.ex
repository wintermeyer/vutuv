defmodule VutuvWeb.ApiV2.ImageController do
  @moduledoc """
  Post image upload over the API: `POST /api/2.0/me/post_images`
  (multipart, the file in the `image` field, optional `alt`) creates a
  pending image; its `id` goes into `image_ids` of `POST /posts`.
  Unattached uploads are swept after a day, or deleted explicitly via
  `DELETE /api/2.0/me/post_images/:id`. Same store, sweeper and audience
  proxy as the composer uploads (`Vutuv.Posts`).
  """

  use VutuvWeb, :controller

  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
  alias Vutuv.UUIDv7
  alias VutuvWeb.ApiV2
  alias VutuvWeb.ApiV2.Problem

  plug(VutuvWeb.Plug.RequireScope, "posts:write")

  def create(conn, %{"image" => %Plug.Upload{} = upload} = params) do
    user = conn.assigns.current_user

    case Posts.create_pending_image(user, upload) do
      {:ok, image} ->
        ApiV2.send_json(conn, image_doc(set_alt(image, params["alt"])), 201)

      {:error, :too_large} ->
        Problem.send_problem(conn, 413, "File too large",
          detail: "Images may have at most #{Posts.max_image_filesize()} bytes."
        )

      {:error, _invalid} ->
        Problem.send_problem(conn, 422, "Invalid image",
          detail: "Send a JPEG, PNG or WebP file in the \"image\" field."
        )
    end
  end

  def create(conn, _params) do
    Problem.send_problem(conn, 400, "Bad request",
      detail: ~s(Send multipart/form-data with the file in the "image" field.)
    )
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with uuid when is_binary(uuid) <- UUIDv7.cast_or_nil(id),
         %PostImage{post_id: nil} = image <-
           Repo.get_by(PostImage, id: uuid, user_id: user.id) do
      Posts.delete_pending_image(image)
      send_resp(conn, 204, "")
    else
      # Attached images belong to their post (edit/delete the post instead).
      _missing_or_attached -> Problem.not_found(conn)
    end
  end

  defp set_alt(image, alt) when is_binary(alt) and alt != "" do
    case Posts.update_image_alt(image, alt) do
      {:ok, image} -> image
      {:error, _changeset} -> image
    end
  end

  defp set_alt(image, _none), do: image

  defp image_doc(%PostImage{} = image) do
    %{
      type: "post_image",
      id: image.id,
      alt: image.alt,
      width: image.width,
      height: image.height,
      content_type: image.content_type,
      # The composer sweep applies to API uploads too.
      attach_within_hours: 24
    }
  end
end
