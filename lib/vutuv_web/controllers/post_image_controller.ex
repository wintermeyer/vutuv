defmodule VutuvWeb.PostImageController do
  @moduledoc """
  The authorizing image proxy: every post-image byte is served through here,
  so a post's audience (deny-model, `Vutuv.Posts.visible_to?/2`) also guards
  its images — switching a post from public to restricted locks its images
  immediately, which statically served files could never do.

  In production the controller answers with `X-Accel-Redirect` and nginx
  streams the file from an `internal` location (auth in the app, bytes by
  nginx). In dev/test it falls back to `send_file` (the sendfile syscall, no
  in-memory buffering). Pending images (post not yet submitted) are visible
  to their uploader alone.

  Version URLs are immutable (the token is random per image), so responses
  carry a long private cache lifetime. Denied and unknown tokens are both
  404 — the proxy must not leak whether an image exists.
  """

  use VutuvWeb, :controller

  alias Vutuv.Posts

  @cache_control "private, max-age=31536000, immutable"

  def show(conn, %{"token" => token, "version" => version_file}) do
    with version when not is_nil(version) <- parse_version(version_file),
         image when not is_nil(image) <- Posts.get_image_by_token(token),
         true <- Posts.image_visible_to?(image, conn.assigns[:current_user]) do
      serve(conn, image, version)
    else
      _ -> not_found(conn)
    end
  end

  # Only "<served version>.webp" resolves; "original.*" never does.
  defp parse_version(version_file) do
    case String.split(version_file, ".") do
      [version, "webp"] -> if version in Vutuv.Posts.PostImage.versions(), do: version
      _ -> nil
    end
  end

  defp serve(conn, image, version) do
    conn =
      conn
      |> put_resp_content_type("image/webp")
      |> put_resp_header("cache-control", @cache_control)

    case Application.get_env(:vutuv, :post_image_serving, :send_file) do
      :accel_redirect ->
        conn
        |> put_resp_header("x-accel-redirect", Vutuv.PostImageStore.accel_path(image, version))
        |> send_resp(200, "")

      _send_file ->
        case Vutuv.PostImageStore.version_path(image, version) do
          nil -> not_found(conn)
          path -> send_file(conn, 200, path)
        end
    end
  end

  defp not_found(conn), do: VutuvWeb.ControllerHelpers.render_error(conn, 404)
end
