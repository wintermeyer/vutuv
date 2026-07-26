defmodule Vutuv.PostImageStore do
  @moduledoc """
  On-disk storage for post images.

  Unlike avatars/covers there is **no public tree**: every served byte goes
  through the authorizing proxy (`VutuvWeb.PostImageController`). The derived
  versions live in one directory per image, keyed by the image's URL token;
  the uploaded original sits in the shared private `originals/` tree
  (`Vutuv.Uploads.Originals`) like every other uploader's:

      <uploads_dir_prefix>/post_images/<token>/thumb.avif
                                              /feed.avif
                                              /large.avif
                                              /xl.avif
      <uploads_dir_prefix>/originals/post_images/<token>/original.<ext>
                                                       /cleaned.<ext>

  Resolution, format and quality of the served versions come from
  `Vutuv.Uploads.Spec`: AVIF, EXIF-autorotated first and then metadata-
  stripped. Pre-AVIF `.webp` versions keep resolving through a transitional
  fallback in `version_path/2`/`accel_path/2` until `Vutuv.Uploads.Regenerator`
  has converted them; `xl` falls back to `large` the same way for photos
  uploaded before that version existed.

  ## The original, and the one way out (issue #1104)

  The original keeps its metadata — that is the point of keeping it: re-deriving
  better formats later. It is **not** reachable by URL construction: no static
  mount, no nginx alias, and `parse_version/1` in the proxy never resolves a
  stored filename.

  There is exactly one path by which full-resolution bytes leave, and it is
  opened per photo by its author: `download_file/1`, behind
  `post_images.download_original`. Even then the default is the **cleaned
  copy** — the same pixels with every metadata block removed
  (`Vutuv.Uploads.MetadataStrip`), cached beside the original — and handing
  out the byte-identical upload is a second, separate choice the composer
  warns about when the file carries a location. A format the stripper cannot
  take apart yields no cleaned copy at all rather than the untouched file.

  HEIC/HEIF input is **capability-detected**: the precompiled vix libvips
  ships libheif without an HEVC decoder (patent licensing), so a `.heic`
  opens (header parse) but fails at pixel decode. `heic_supported?/0` forces
  a real decode of a tiny shipped probe once and caches the result; the
  extension whitelist includes `.heic`/`.heif` only when the running build
  can actually decode them. On a server with a full libvips (e.g. platform-
  provided via `VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS`), HEIC
  uploads start working without a code change.
  """

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation
  alias Vutuv.Posts.PostImage
  alias Vutuv.Uploads.Exif
  alias Vutuv.Uploads.MetadataStrip
  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @base_extension_whitelist ~w(.jpg .jpeg .png .webp)
  @heic_extensions ~w(.heic .heif)

  def extension_whitelist do
    if heic_supported?() do
      @base_extension_whitelist ++ @heic_extensions
    else
      @base_extension_whitelist
    end
  end

  @doc """
  Whether this libvips build can actually *decode* HEIC pixels (libheif with
  an HEVC decoder). Header-only checks lie — opening succeeds on builds that
  cannot decode — so the probe runs a real decode of a tiny shipped sample,
  once, and caches the verdict for the VM's lifetime.
  """
  def heic_supported? do
    case :persistent_term.get({__MODULE__, :heic_supported}, :unknown) do
      :unknown ->
        probe = Path.join(:code.priv_dir(:vutuv), "heic_probe.heic")

        # vips evaluates lazily: opening/thumbnailing succeeds on builds that
        # cannot decode HEVC — only materializing pixels surfaces the error.
        supported =
          with {:ok, image} <- Image.thumbnail(probe, "8x8"),
               {:ok, _binary} <- VipsImage.write_to_binary(image) do
            true
          else
            _ -> false
          end

        :persistent_term.put({__MODULE__, :heic_supported}, supported)
        supported

      verdict ->
        verdict
    end
  end

  @doc """
  Stores every version for `upload` under a fresh `token` directory and
  returns `{:ok, %{width:, height:, content_type:, size_bytes:}}` (dimensions
  are post-rotation) or `{:error, :invalid_file}` when the extension is not
  whitelisted or the file cannot be decoded.
  """
  def store(%Plug.Upload{} = upload, token) do
    store(upload.path, upload.filename, token)
  end

  def store(path, filename, token) do
    ext = filename |> Path.extname() |> String.downcase()

    if ext in extension_whitelist() do
      dir = dir(token)
      File.mkdir_p!(dir)

      case write_versions(path, ext, dir, token) do
        {:ok, meta} ->
          {:ok, Map.merge(meta, %{content_type: MIME.from_path(filename)})}

        {:error, _reason} ->
          File.rm_rf(dir)
          {:error, :invalid_file}
      end
    else
      {:error, :invalid_file}
    end
  end

  # Decode + rotate once, then derive all versions from the rotated image.
  # The derived writes go first: they prove the file decodes before the
  # original is copied (house pattern shared with Vutuv.Avatar/Cover).
  #
  # The camera facts are read from the image **before** autorotation (issue
  # #1104): rotating rewrites the header and on some libvips builds drops the
  # EXIF block with it, so reading afterwards would silently return nothing.
  defp write_versions(path, ext, dir, token) do
    with {:ok, opened} <- Image.open(path),
         camera = Exif.read_image(opened),
         {:ok, rotated} <- Spec.open_rotated(path),
         :ok <- write_derived_versions(rotated, dir) do
      :ok = Originals.store(storage_dir(token), path, ext)
      # A re-store under the same token must not leave the previous upload's
      # cleaned copy behind for the download route to serve — whatever
      # extension that one had.
      clear_cleaned(token)

      {:ok,
       Map.merge(camera, %{
         width: Image.width(rotated),
         height: Image.height(rotated),
         size_bytes: File.stat!(path).size
       })}
    end
  end

  defp write_derived_versions(rotated, dir) do
    Spec.write_all(:post_image, rotated, fn spec ->
      Path.join(dir, "#{spec.name}#{Spec.served_ext()}")
    end)
  end

  @doc """
  Re-derives every served version from the original per the current
  `Vutuv.Uploads.Spec` — see `Vutuv.Uploads.regenerate_from_original/3`,
  which this configures with the post-image layout (the legacy original
  lived inside the token dir itself). Used by `Vutuv.Uploads.Regenerator`.
  """
  def regenerate(%PostImage{token: token}, opts \\ []) do
    dir = dir(token)

    Vutuv.Uploads.regenerate_from_original(storage_dir(token), dir,
      canonical: canonical_filenames(),
      stale_glob: "*",
      legacy_candidates: [Path.join(dir, "original.*")],
      derive: &write_derived_versions(&1, dir),
      opts: opts
    )
  end

  defp canonical_filenames do
    for spec <- Spec.versions(:post_image), do: "#{spec.name}#{Spec.served_ext()}"
  end

  @doc """
  Absolute on-disk path of a *served* version (`"thumb" | "feed" | "large"`),
  or `nil` when the file is missing. Never resolves the original.
  """
  def version_path(%PostImage{token: token}, version) do
    if filename = version_filename(token, version) do
      Path.join(dir(token), filename)
    end
  end

  @og_width 1200

  @doc """
  The dimensions `og_jpeg/1` serves, computed from the stored
  (post-rotation) dimensions: width capped at #{@og_width}px, aspect kept,
  never upscaled. Lets the `og:image:width`/`height` tags render without
  disk I/O (`VutuvWeb.OpenGraph`).
  """
  def og_dimensions(%PostImage{width: width, height: height}) when width > @og_width do
    {@og_width, round(height * @og_width / width)}
  end

  def og_dimensions(%PostImage{width: width, height: height}), do: {width, height}

  @doc """
  The image as JPEG bytes for the link preview (`og:image` — preview
  scrapers don't decode AVIF): derived on the fly from the private
  original, or from the largest served version when no original exists,
  width-capped per `og_dimensions/1` and metadata-stripped (`keep: []` —
  the original's EXIF/GPS must not leak, the rule the AVIF pipeline
  enforces too). `:error` when nothing usable is on disk.
  """
  def og_jpeg(%PostImage{token: token} = image) do
    with path when not is_nil(path) <- og_source(image, token),
         {:ok, rotated} <- Spec.open_rotated(path),
         {:ok, capped} <- Image.thumbnail(rotated, "#{@og_width}", resize: :down),
         {:ok, data} <- Operation.jpegsave_buffer(capped, keep: [], Q: 80) do
      {:ok, data}
    else
      _ -> :error
    end
  end

  defp og_source(image, token) do
    Originals.path(storage_dir(token)) || version_path(image, "large")
  end

  @doc """
  The path nginx resolves inside its `internal` alias location (production
  X-Accel-Redirect target), pointing at the resolved on-disk file so
  not-yet-regenerated `.webp` versions keep streaming. Defaults to the
  canonical `.avif` name when nothing is stored (nginx then 404s).
  """
  def accel_path(%PostImage{token: token}, version) when is_binary(version) do
    filename = version_filename(token, version) || "#{version}#{Spec.served_ext()}"
    "/internal_post_images/#{token}/#{filename}"
  end

  # The .avif is authoritative; until the regeneration has run, a pre-AVIF
  # `.webp` version keeps resolving. Transitional — remove together with
  # `Spec.legacy_exts/0`.
  #
  # `xl` (issue #1104) has its own fallback for the same reason in reverse:
  # every photo uploaded before it existed has no `xl` file, and the lightbox
  # must still show something. It resolves to `large` until
  # `Vutuv.Uploads.Regenerator` has derived the bigger version — a slightly
  # softer picture on a big screen, never a broken one.
  defp version_filename(token, version) do
    if version in PostImage.versions() do
      dir = dir(token)

      version
      |> version_candidates()
      |> Enum.find(&File.exists?(Path.join(dir, &1)))
    end
  end

  defp version_candidates("xl"), do: candidates("xl") ++ candidates("large")
  defp version_candidates(version), do: candidates(version)

  defp candidates(version), do: ["#{version}#{Spec.served_ext()}", "#{version}.webp"]

  @doc """
  The on-disk file the **original download** serves for `image`, as
  `{path, ext}`, or `nil` when there is nothing safe to hand out (issue
  #1104).

  Two files can be meant, and the author picks which:

    * `download_exact` — the upload itself, byte for byte, metadata and all.
    * otherwise the **cleaned copy**: the same pixels with every metadata
      block removed (`Vutuv.Uploads.MetadataStrip`), derived once on first
      request and cached beside the original.

  It **fails closed**. A format the stripper cannot take apart safely yields
  `nil` for the cleaned variant rather than falling back to the untouched
  file, because the whole point of that choice is the promise that the file
  carries nothing but the picture.

  Authorization is *not* checked here — `VutuvWeb.PostImageController` owns
  that, as it does for every other version.
  """
  def download_file(%PostImage{token: token} = image) do
    case Originals.path(storage_dir(token)) do
      nil -> nil
      original -> download_file(image, original, Path.extname(original))
    end
  end

  defp download_file(%PostImage{download_exact: true}, original, ext), do: {original, ext}

  defp download_file(%PostImage{token: token}, original, ext) do
    cleaned = cleaned_path(token, ext)

    cond do
      File.exists?(cleaned) -> {cleaned, ext}
      not MetadataStrip.supported?(ext) -> nil
      true -> write_cleaned(original, cleaned, ext)
    end
  end

  defp write_cleaned(original, cleaned, ext) do
    case MetadataStrip.strip(original, ext) do
      :unsupported ->
        nil

      bytes ->
        File.mkdir_p!(Path.dirname(cleaned))
        # Write beside the target and rename, so two concurrent downloads can
        # never serve a half-written file.
        temp = "#{cleaned}.#{System.unique_integer([:positive])}"
        File.write!(temp, bytes)
        File.rename!(temp, cleaned)
        {cleaned, ext}
    end
  end

  @doc """
  Whether a cleaned copy can be produced for this photo at all — what the
  composer asks before it offers the choice, so an author is never promised a
  file the download route would then refuse.
  """
  def cleanable?(%PostImage{token: token}) do
    case Originals.path(storage_dir(token)) do
      nil -> false
      original -> MetadataStrip.supported?(Path.extname(original))
    end
  end

  # The cleaned copy lives in the private originals tree, not beside the
  # served versions: that directory has no static mount and no nginx alias, so
  # the file can only ever leave through the authorizing proxy. (It would also
  # be swept by the regenerator's stale glob if it sat with the versions.)
  defp cleaned_path(token, ext) do
    Path.join(Originals.dir(storage_dir(token)), "cleaned#{ext}")
  end

  defp clear_cleaned(token) do
    storage_dir(token)
    |> Originals.dir()
    |> Path.join("cleaned.*")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)
  end

  @doc "Removes every stored file of `token`. A no-op when nothing is stored."
  def delete(token) when is_binary(token) do
    File.rm_rf(dir(token))
    Originals.delete(storage_dir(token))
    :ok
  end

  defp storage_dir(token) do
    # The token is Base64-URL ([A-Za-z0-9_-]) by construction, but never
    # trust a stored value enough to build paths with separators in it.
    false = String.contains?(token, ["/", ".."])
    Path.join("post_images", token)
  end

  defp dir(token), do: Vutuv.Uploads.disk_dir(storage_dir(token))
end
