defmodule VutuvWeb.PostImageController do
  @moduledoc """
  The authorizing image proxy: every post-image byte is served through here,
  so a post's audience (deny-model, `Vutuv.Posts.visible_to?/2`) also guards
  its images — switching a post from public to restricted locks its images
  immediately, which statically served files could never do.

  The serving mechanics (X-Accel-Redirect vs `send_file`, the version parser,
  the immutable cache header) live in `VutuvWeb.ImageProxy`, shared with the
  job-posting and organization proxies; this controller owns the post policy,
  the on-the-fly `og.jpg` and the download filename. Pending images (post not
  yet submitted) are visible to their uploader alone; denied and unknown
  tokens are both 404 — the proxy must not leak whether an image exists.
  """

  use VutuvWeb, :controller

  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
  alias VutuvWeb.ImageProxy

  def show(conn, %{"token" => token, "version" => version_file}) do
    with version when not is_nil(version) <- parse_version(version_file),
         image when not is_nil(image) <- Posts.get_image_by_token(token),
         true <- Posts.image_visible_to?(image, conn.assigns[:current_user]) do
      serve(conn, image, version)
    else
      _ -> ImageProxy.not_found(conn)
    end
  end

  # "og.jpg" is the link-preview JPEG (og:image), derived on the fly rather
  # than stored; everything else resolves through the shared whitelist parser
  # ("original.*" never does).
  defp parse_version("og.jpg"), do: :og

  defp parse_version(version_file),
    do: ImageProxy.parse_version(version_file, PostImage.versions())

  # The og.jpg bytes are generated in the app (Vutuv.PostImageStore.og_jpeg/1),
  # so they are sent directly in both serving modes — there is no file for
  # nginx to accel-stream. Rare traffic: one fetch per scrape, then cached.
  defp serve(conn, image, :og) do
    case Vutuv.PostImageStore.og_jpeg(image) do
      {:ok, jpeg} ->
        conn
        |> ImageProxy.put_cache_control()
        |> put_download_name(image, "og", "jpg")
        |> put_resp_content_type("image/jpeg")
        |> send_resp(200, jpeg)

      :error ->
        ImageProxy.not_found(conn)
    end
  end

  defp serve(conn, image, version) do
    ImageProxy.serve(conn, version,
      accel_path: &Vutuv.PostImageStore.accel_path(image, &1),
      version_path: &Vutuv.PostImageStore.version_path(image, &1),
      decorate: &put_download_name(&1, image, version, &2)
    )
  end

  # Suggest a download filename carrying the owner's handle, e.g.
  # `ada_king-feed.avif`. `inline` (not `attachment`), so it only changes the
  # name a browser proposes on "Save as", not whether the image renders inline.
  defp put_download_name(conn, image, version, ext) do
    case image.user do
      %{username: slug} when is_binary(slug) ->
        name = "#{slug}-#{version}.#{String.trim_leading(ext, ".")}"
        put_resp_header(conn, "content-disposition", ~s(inline; filename="#{name}"))

      _ ->
        conn
    end
  end
end
