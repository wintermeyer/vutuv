defmodule Vutuv.Screenshot do
  @moduledoc """
  URL-screenshot storage and URL generation.

  Explicit local-disk storage with libvips; the served thumb's resolution,
  format and quality come from `Vutuv.Uploads.Spec` (800x528 AVIF — 2x its
  400x264 on-page display size, so it stays crisp on HiDPI screens):

      <uploads_dir_prefix>/screenshots/<url.id>/thumb-<hash>.avif
      <uploads_dir_prefix>/originals/screenshots/<url.id>/original<ext>

  Thumb filenames are **content-fingerprinted**: `<hash>` is the first 12 hex
  chars of the SHA-256 of the captured image. Because the URL changes whenever
  the image bytes change, the files can be cached forever and browsers never
  serve a stale screenshot (no `?v=` query needed). The `screenshot` field
  stores `<hash><ext>` so both the thumb name and the original's extension can
  be rebuilt.

  The captured original keeps its format in the private `originals/` tree
  (`Vutuv.Uploads.Originals`) and is never served. URLs are root-relative
  (`/screenshots/<id>/...`, nginx `location /screenshots/`); pre-AVIF `.webp`
  thumbs keep resolving through a transitional fallback in `url/2` until the
  one-shot regeneration has converted them.
  """

  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @extension_whitelist ~w(.jpg .png .webp)

  @doc """
  Stores the screenshot versions for `{upload, url}` and returns
  `{:ok, "<hash><ext>"}` (to persist in the `screenshot` field), or
  `{:error, :invalid_file}`.
  """
  def store({%Plug.Upload{} = upload, scope}) do
    if valid_extension?(upload.filename) do
      dir = disk_dir(scope)
      File.mkdir_p!(dir)
      hash = Vutuv.Uploads.content_hash(upload.path)
      ext = Path.extname(upload.filename)

      with {:ok, rotated} <- Spec.open_rotated(upload.path),
           # Remove any prior versions first so a regeneration leaves exactly
           # one fingerprinted thumb behind instead of accumulating files.
           :ok <- clear_versions(dir),
           :ok <- write_thumb(rotated, dir, hash) do
        :ok = Originals.store(storage_dir(scope), upload.path, ext)
        {:ok, "#{hash}#{ext}"}
      else
        _ -> {:error, :invalid_file}
      end
    else
      {:error, :invalid_file}
    end
  end

  @doc """
  Re-derives the served thumb from the original per the current
  `Vutuv.Uploads.Spec` — see `Vutuv.Uploads.regenerate_from_original/3`,
  which this configures with the screenshot layout. Used by
  `Vutuv.Uploads.Regenerator`.
  """
  def regenerate(url, opts \\ []) do
    dir = disk_dir(url)
    hash = rootname(url.screenshot)

    Vutuv.Uploads.regenerate_from_original(storage_dir(url), dir,
      canonical: [thumb_filename(hash, Spec.served_ext())],
      stale_glob: "{thumb,original}*",
      legacy_candidates: [Path.join(dir, "original-*")],
      derive: &write_thumb(&1, dir, hash),
      opts: opts
    )
  end

  @doc """
  Root-relative URL for the served thumb, `nil` for `:original` (the original
  is never URL-addressable). Falls back to the bundled
  `/images/screenshot.png` placeholder when there is no screenshot.
  """
  def url(file_and_scope, version \\ :thumb)

  def url({nil, _scope}, :thumb), do: "/images/screenshot.png"
  def url({_screenshot, _scope}, :original), do: nil

  def url({screenshot, scope}, :thumb) do
    "/"
    |> Path.join(Path.join(storage_dir(scope), served_filename(scope, screenshot)))
    |> URI.encode()
  end

  @doc """
  Removes the screenshot files for `url` — the served thumb and the private
  original. A no-op when none. Called when a URL or its owner's account is
  deleted (the DB cascade drops the `urls` row but never its files).
  """
  def delete(url) do
    File.rm_rf(disk_dir(url))
    Originals.delete(storage_dir(url))
    :ok
  end

  # Also sweeps pre-AVIF leftovers: legacy `.webp` thumbs and the originals
  # that used to live in this public directory.
  defp clear_versions(dir) do
    for file <- Path.wildcard(Path.join(dir, "{thumb,original}*")), do: File.rm(file)
    :ok
  end

  defp write_thumb(rotated, dir, hash) do
    spec = Spec.version(:screenshot, :thumb)
    Spec.write_derived(spec, rotated, Path.join(dir, thumb_filename(hash, Spec.served_ext())))
  end

  # The .avif is authoritative; until the regeneration has run, a pre-AVIF
  # `.webp` thumb keeps resolving. Transitional — remove together with
  # `Spec.legacy_exts/0`.
  defp served_filename(scope, screenshot) do
    avif = thumb_filename(rootname(screenshot), Spec.served_ext())

    cond do
      File.exists?(Path.join(disk_dir(scope), avif)) -> avif
      (legacy = legacy_filename(scope, screenshot)) != nil -> legacy
      true -> avif
    end
  end

  defp legacy_filename(scope, screenshot) do
    candidate = thumb_filename(rootname(screenshot), ".webp")
    if File.exists?(Path.join(disk_dir(scope), candidate)), do: candidate
  end

  defp thumb_filename(hash, ext), do: "thumb-#{hash}#{ext}"

  defp storage_dir(scope), do: "screenshots/#{scope.id}"

  defp disk_dir(scope), do: Vutuv.Uploads.disk_dir(storage_dir(scope))

  defp rootname(nil), do: ""

  defp rootname(value) when is_binary(value),
    do: value |> Vutuv.Uploads.strip_query() |> Path.rootname()

  defp valid_extension?(file_name) do
    extension = file_name |> Path.extname() |> String.downcase()
    extension in @extension_whitelist
  end
end
