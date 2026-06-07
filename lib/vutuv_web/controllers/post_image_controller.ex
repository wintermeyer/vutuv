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

  # Only "<served version>.<served ext>" resolves; "original.*" never does.
  # The legacy ".webp" extension stays accepted (old stored post bodies and
  # bookmarked URLs carry it) — the response is whatever file is on disk,
  # with the matching content type.
  defp parse_version(version_file) do
    case String.split(version_file, ".") do
      [version, ext] when ext in ["avif", "webp"] ->
        if version in Vutuv.Posts.PostImage.versions(), do: version

      _ ->
        nil
    end
  end

  defp serve(conn, image, version) do
    conn = put_resp_header(conn, "cache-control", @cache_control)

    case Application.get_env(:vutuv, :post_image_serving, :send_file) do
      :accel_redirect ->
        accel_path = Vutuv.PostImageStore.accel_path(image, version)

        conn
        |> put_resp_content_type(MIME.from_path(accel_path))
        |> put_resp_header("x-accel-redirect", accel_path)
        |> send_resp(200, "")

      _send_file ->
        case Vutuv.PostImageStore.version_path(image, version) do
          nil ->
            not_found(conn)

          path ->
            conn
            |> put_resp_content_type(MIME.from_path(path))
            |> send_file(200, path)
        end
    end
  end

  defp not_found(conn), do: VutuvWeb.ControllerHelpers.render_error(conn, 404)
end
