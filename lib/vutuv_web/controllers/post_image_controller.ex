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
  alias Vutuv.Posts.PostImage

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
  # with the matching content type. "og.jpg" is the link-preview JPEG
  # (og:image), derived on the fly rather than stored.
  defp parse_version("og.jpg"), do: :og

  defp parse_version(version_file) do
    case String.split(version_file, ".") do
      [version, ext] when ext in ["avif", "webp"] ->
        if version in PostImage.versions(), do: version

      _ ->
        nil
    end
  end

  # The og.jpg bytes are generated in the app (Vutuv.PostImageStore.og_jpeg/1),
  # so they are sent directly in both serving modes — there is no file for
  # nginx to accel-stream. Rare traffic: one fetch per scrape, then cached.
  defp serve(conn, image, :og) do
    case Vutuv.PostImageStore.og_jpeg(image) do
      {:ok, jpeg} ->
        conn
        |> put_resp_header("cache-control", @cache_control)
        |> put_download_name(image, "og", "jpg")
        |> put_resp_content_type("image/jpeg")
        |> send_resp(200, jpeg)

      :error ->
        not_found(conn)
    end
  end

  defp serve(conn, image, version) do
    conn = put_resp_header(conn, "cache-control", @cache_control)

    case Application.get_env(:vutuv, :post_image_serving, :send_file) do
      :accel_redirect ->
        accel_path = Vutuv.PostImageStore.accel_path(image, version)

        conn
        |> put_resp_content_type(MIME.from_path(accel_path))
        |> put_download_name(image, version, Path.extname(accel_path))
        |> put_resp_header("x-accel-redirect", accel_path)
        |> send_resp(200, "")

      _send_file ->
        case Vutuv.PostImageStore.version_path(image, version) do
          nil ->
            not_found(conn)

          path ->
            conn
            |> put_resp_content_type(MIME.from_path(path))
            |> put_download_name(image, version, Path.extname(path))
            |> send_file(200, path)
        end
    end
  end

  # Suggest a download filename carrying the owner's handle, e.g.
  # `ada_king-feed.avif`. `inline` (not `attachment`), so it only changes the
  # name a browser proposes on "Save as", not whether the image renders inline.
  defp put_download_name(conn, image, version, ext) do
    case image.user do
      %{active_slug: slug} when is_binary(slug) ->
        name = "#{slug}-#{version}.#{String.trim_leading(ext, ".")}"
        put_resp_header(conn, "content-disposition", ~s(inline; filename="#{name}"))

      _ ->
        conn
    end
  end

  defp not_found(conn), do: VutuvWeb.ControllerHelpers.render_error(conn, 404)
end
