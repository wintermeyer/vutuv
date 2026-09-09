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
  alias Vutuv.PressKit
  alias Vutuv.PressKitStore
  alias VutuvWeb.ImageProxy

  def show(conn, %{"token" => token, "version" => version_file}) do
    with image when not is_nil(image) <- PressKit.get_by_token(token),
         version when not is_nil(version) <- parse_version(version_file, image),
         true <- PressKit.visible_to?(image, conn.assigns[:current_user]) do
      serve(conn, image, version)
    else
      _ -> ImageProxy.not_found(conn)
    end
  end

  # The two file addresses are named rather than parsed as versions: neither is
  # a size of the picture, and nothing that enumerates versions should offer
  # them. Everything else goes through the shared whitelist parser, which never
  # resolves a stored filename — and the whitelist is the shelf's, so a logo
  # cannot be asked for the lightbox size it does not have.
  defp parse_version("download.orig", _image), do: :download
  defp parse_version("download.png", image), do: if(Image.logo?(image), do: :png)

  defp parse_version(version_file, image),
    do: ImageProxy.parse_version(version_file, PressKitStore.versions(image))

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
end
