defmodule Vutuv.Screenshot do
  @moduledoc """
  URL-screenshot storage and URL generation.

  Replaces the former Waffle uploader with explicit local-disk storage and
  libvips (`Image`). The layout matches what production already serves (nginx
  `location /screenshots/` aliases the storage directory):

      <uploads_dir_prefix>/screenshots/<url.id>/<version>-<hash><ext>

  Filenames are **content-fingerprinted**: `<hash>` is the first 12 hex chars
  of the SHA-256 of the uploaded image. Because the URL changes whenever the
  image bytes change, the files can be cached forever and browsers never serve
  a stale screenshot (no `?v=` query needed). The `screenshot` field stores
  `<hash><ext>` so `url/2` can rebuild both filenames.

  The `:thumb` version is always rendered as an 800x528 WebP; `:original` keeps
  the uploaded extension. URLs are root-relative (`/screenshots/<id>/...`).

  The thumb is generated at 2x its on-page display size (400x264) so it stays
  crisp on HiDPI / Retina screens.
  """

  @extension_whitelist ~w(.jpg .png .webp)
  @thumb_width 800
  @thumb_height 528
  @thumb_quality 85
  @hash_length 12

  @doc """
  Stores the screenshot versions for `{upload, url}` and returns
  `{:ok, "<hash><ext>"}` (to persist in the `screenshot` field), or
  `{:error, :invalid_file}`.
  """
  def store({%Plug.Upload{} = upload, scope}) do
    if valid_extension?(upload.filename) do
      dir = disk_dir(scope)
      File.mkdir_p!(dir)
      hash = content_hash(upload.path)
      ext = Path.extname(upload.filename)

      # Remove any prior versions first so a regeneration leaves exactly one
      # fingerprinted thumb/original behind instead of accumulating files.
      clear_versions(dir)
      write_original(upload, dir, hash, ext)
      write_thumb(upload, dir, hash)
      {:ok, "#{hash}#{ext}"}
    else
      {:error, :invalid_file}
    end
  end

  @doc """
  Root-relative URL for a screenshot version. Falls back to the bundled
  `/images/screenshot.png` placeholder when there is no screenshot.
  """
  def url(file_and_scope, version \\ :thumb)

  def url({nil, _scope}, :thumb), do: "/images/screenshot.png"

  def url({screenshot, scope}, version) do
    "/"
    |> Path.join(Path.join(storage_dir(scope), version_filename(version, screenshot)))
    |> URI.encode()
  end

  defp content_hash(path) do
    :sha256
    |> :crypto.hash(File.read!(path))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_length)
  end

  defp clear_versions(dir) do
    for file <- Path.wildcard(Path.join(dir, "{thumb,original}*")), do: File.rm(file)
    :ok
  end

  defp write_original(upload, dir, hash, ext) do
    File.cp!(upload.path, Path.join(dir, "original-#{hash}#{ext}"))
  end

  defp write_thumb(upload, dir, hash) do
    {:ok, image} =
      Image.thumbnail(upload.path, "#{@thumb_width}x#{@thumb_height}", crop: :high)

    {:ok, _} = Image.write(image, Path.join(dir, "thumb-#{hash}.webp"), quality: @thumb_quality)
  end

  defp version_filename(:thumb, screenshot), do: "thumb-#{rootname(screenshot)}.webp"

  defp version_filename(:original, screenshot),
    do: "original-#{rootname(screenshot)}#{extname(screenshot)}"

  defp storage_dir(scope), do: "screenshots/#{scope.id}"

  defp disk_dir(scope), do: Vutuv.Uploads.disk_dir(storage_dir(scope))

  defp rootname(nil), do: ""

  defp rootname(value) when is_binary(value),
    do: value |> Vutuv.Uploads.strip_query() |> Path.rootname()

  defp extname(nil), do: ""

  defp extname(value) when is_binary(value),
    do: value |> Vutuv.Uploads.strip_query() |> Path.extname()

  defp valid_extension?(file_name) do
    extension = file_name |> Path.extname() |> String.downcase()
    extension in @extension_whitelist
  end
end
