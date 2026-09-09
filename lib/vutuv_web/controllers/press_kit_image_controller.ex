defmodule VutuvWeb.PressKitImageController do
  @moduledoc """
  The authorizing press-kit proxy (issue #2083): every byte of a press photo or
  a logo variant goes through here, so the row is the off switch — a picture the
  AI gate has not released, and a frozen one, answer 404 to everybody who is not
  allowed to see it (`Vutuv.PressKit.visible_to?/2`).

  The serving mechanics (the version parser, the X-Accel / `send_file` switch,
  the immutable cache header) are `VutuvWeb.ImageProxy`'s, shared with the post,
  job-posting and organization proxies. What this one owns is the two addresses
  a *file* leaves at, which no other proxy has as its main purpose:

    * `download.orig` — the picture a journalist takes away. For a photo that is
      the **cleaned** original: the same pixels with every metadata block
      removed, so a press photo never hands out a GPS fix or a camera serial.
      For a logo uploaded as SVG it is the vector itself.
    * `download.png` — a logo variant's PNG rendering, for whoever cannot use a
      vector. 404 on a photo, which has no such thing.
    * `pixelated.avif` — the stand-in a stranger meets while the AI check is
      looking at the picture (issue #2084). The one address here that answers a
      reader `visible_to?/2` refuses, and the one that redirects rather than
      sending bytes once the verdict has landed, so a page rendered before it
      never draws a broken image.

  **The two downloads are `attachment`, and every response carries `nosniff`.**
  vutuv rasterises SVGs and never renders one, and an SVG rendered inline on our
  own origin is a script on our own origin — so the one route by which a vector
  leaves says it is a file to save. The `nosniff` beside it is the router's, not
  this controller's: `put_secure_browser_headers` in the `:browser` pipeline
  already sets it on every response here (measured — a copy in this controller
  changed no header on any of its eight tests), so do not add a second one.
  Denied and unknown tokens are both 404, as everywhere on these proxies: the
  answer must not say whether a picture exists.
  """

  use VutuvWeb, :controller

  alias Vutuv.Images.Image
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.PressKit
  alias Vutuv.PressKitStore
  alias VutuvWeb.ImageProxy

  def show(conn, %{"token" => token, "version" => version_file}) do
    with image when not is_nil(image) <- PressKit.get_by_token(token),
         version when not is_nil(version) <- parse_version(version_file, image),
         true <- allowed?(image, conn.assigns[:current_user], version) do
      serve(conn, image, version)
    else
      _ -> ImageProxy.not_found(conn)
    end
  end

  # The stand-in is the mirror image of the picture: it answers for exactly the
  # reader the picture refuses. Both are allowed, so a URL rendered before the
  # verdict still resolves after it — the owner's own page is drawn from the
  # picture and would otherwise 404 on a stale stand-in URL in a cache.
  defp allowed?(image, viewer, :pixelated),
    do: PressKit.pixelated_visible?(image) or PressKit.visible_to?(image, viewer)

  defp allowed?(image, viewer, _version), do: PressKit.visible_to?(image, viewer)

  # The three named addresses are named rather than parsed as versions: none of
  # them is a size of the picture, and nothing that enumerates versions should
  # offer them. Everything else goes through the shared whitelist parser, which
  # never resolves a stored filename — and the whitelist is the shelf's, so a
  # logo cannot be asked for the lightbox size it does not have.
  defp parse_version("download.orig", _image), do: :download
  defp parse_version("download.png", image), do: if(Image.logo?(image), do: :png)
  defp parse_version("pixelated.avif", _image), do: :pixelated

  defp parse_version(version_file, image),
    do: ImageProxy.parse_version(version_file, PressKitStore.versions(image))

  # A released picture hands its URL back to itself rather than 404ing on a
  # stand-in that was deleted seconds ago: `large` is the size both shelves have.
  defp serve(conn, image, :pixelated) do
    if ImageScans.released?(image.moderation) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> redirect(to: PressKit.url(image, "large"))
    else
      ImageProxy.serve_pixelated(conn, existing(PressKitStore.pixelated_path(image.token)))
    end
  end

  defp serve(conn, image, :download),
    do: hand_over(conn, PressKitStore.download_file(image), image)

  defp serve(conn, image, :png),
    do: hand_over(conn, PressKitStore.png_download_file(image), image)

  defp serve(conn, image, version) do
    ImageProxy.serve(conn, version,
      accel_path: &PressKitStore.accel_path(image.token, &1),
      version_path: &PressKitStore.version_path(image.token, &1)
    )
  end

  # `ImageProxy.hand_over/3` rather than `serve/3`, shared with the post proxy —
  # see it for why the private originals tree must never reach the X-Accel
  # branch.
  defp hand_over(conn, nil, _image), do: ImageProxy.not_found(conn)

  defp hand_over(conn, {path, ext}, image),
    do: ImageProxy.hand_over(conn, path, PressKit.download_name(image, ext))

  # A stand-in that is not on disk is the proxy's usual 404 rather than a crash
  # in `send_file` — the same guard the post proxy keeps for the same reason.
  defp existing(path), do: if(File.exists?(path), do: path)
end
