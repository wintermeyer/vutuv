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
      <uploads_dir_prefix>/originals/post_images/<token>/original.<ext>

  Resolution, format and quality of the served versions come from
  `Vutuv.Uploads.Spec`: AVIF, EXIF-autorotated first and then metadata-
  stripped. The original keeps its metadata (that is the point of keeping it:
  re-deriving better formats later) and is **never** served; in production the
  nginx `internal` location only matches the served version filenames, and the
  proxy never redirects to an original. Pre-AVIF `.webp` versions keep
  resolving through a transitional fallback in `version_path/2`/`accel_path/2`
  until `Vutuv.Uploads.Regenerator` has converted them.

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
  alias Vutuv.Posts.PostImage
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
  defp write_versions(path, ext, dir, token) do
    with {:ok, rotated} <- Spec.open_rotated(path),
         :ok <- write_derived_versions(rotated, dir) do
      :ok = Originals.store(storage_dir(token), path, ext)

      {:ok,
       %{
         width: Image.width(rotated),
         height: Image.height(rotated),
         size_bytes: File.stat!(path).size
       }}
    end
  end

  defp write_derived_versions(rotated, dir) do
    Enum.reduce_while(Spec.versions(:post_image), :ok, fn spec, :ok ->
      dest = Path.join(dir, "#{spec.name}#{Spec.served_ext()}")

      case Spec.write_derived(spec, rotated, dest) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
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
         {:ok, data} <- Vix.Vips.Operation.jpegsave_buffer(capped, keep: [], Q: 80) do
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
  defp version_filename(token, version) do
    if version in PostImage.versions() do
      dir = dir(token)
      avif = "#{version}#{Spec.served_ext()}"
      webp = "#{version}.webp"

      cond do
        File.exists?(Path.join(dir, avif)) -> avif
        File.exists?(Path.join(dir, webp)) -> webp
        true -> nil
      end
    end
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
