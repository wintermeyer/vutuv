defmodule Vutuv.PostImageStore do
  @moduledoc """
  On-disk storage for post images.

  Unlike avatars/covers there is **no public tree**: every byte is served
  through the authorizing proxy (`VutuvWeb.PostImageController`), so all
  versions live together in one private directory per image, keyed by the
  image's URL token:

      <uploads_dir_prefix>/post_images/<token>/thumb.webp
                                              /feed.webp
                                              /large.webp
                                              /original.<ext>

  The derived versions are WebP, EXIF-autorotated first and then metadata-
  stripped (orientation is itself EXIF data — stripping before rotating would
  render every portrait phone photo sideways). The original keeps its
  metadata (that is the point of keeping it: re-deriving better formats
  later) and is **never** served; in production the nginx `internal` location
  only matches `*.webp`, and the proxy never redirects to it.

  HEIC/HEIF input is **capability-detected**: the precompiled vix libvips
  ships libheif without an HEVC decoder (patent licensing), so a `.heic`
  opens (header parse) but fails at pixel decode. `heic_supported?/0` forces
  a real decode of a tiny shipped probe once and caches the result; the
  extension whitelist includes `.heic`/`.heif` only when the running build
  can actually decode them. On a server with a full libvips (e.g. platform-
  provided via `VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS`), HEIC
  uploads start working without a code change.
  """

  alias Vutuv.Posts.PostImage

  @base_extension_whitelist ~w(.jpg .jpeg .png .webp)
  @heic_extensions ~w(.heic .heif)
  # thumb: square feed-grid cell; feed: single-image feed width; large:
  # permalink/lightbox. feed/large fit within the box (no upscale), thumb is
  # a center crop.
  @fit_dimensions %{feed: 1200, large: 1600}
  @thumb_size 320
  @quality 80

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
               {:ok, _binary} <- Vix.Vips.Image.write_to_binary(image) do
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

      case write_versions(path, ext, dir) do
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
  # original is copied (house pattern from Vutuv.Avatar).
  defp write_versions(path, ext, dir) do
    with {:ok, image} <- Image.open(path),
         {:ok, {rotated, _flags}} <- Image.autorotate(image),
         :ok <- write_thumb(rotated, dir),
         :ok <- write_fitted(rotated, dir, :feed),
         :ok <- write_fitted(rotated, dir, :large) do
      File.cp!(path, Path.join(dir, "original#{ext}"))

      {:ok,
       %{
         width: Image.width(rotated),
         height: Image.height(rotated),
         size_bytes: File.stat!(path).size
       }}
    end
  end

  defp write_thumb(image, dir) do
    with {:ok, thumb} <- Image.thumbnail(image, "#{@thumb_size}x#{@thumb_size}", crop: :center) do
      write_webp(thumb, Path.join(dir, "thumb.webp"))
    end
  end

  defp write_fitted(image, dir, version) do
    size = Map.fetch!(@fit_dimensions, version)

    # resize: :down so a smaller upload keeps its native size instead of
    # being blurrily upscaled.
    with {:ok, fitted} <- Image.thumbnail(image, "#{size}x#{size}", resize: :down) do
      write_webp(fitted, Path.join(dir, "#{version}.webp"))
    end
  end

  # Straight to vix: `Image.write(..., strip_metadata: true)` maps to the
  # legacy `strip` saver param, which current libvips builds accept and
  # silently ignore — EXIF (incl. GPS) survived into the WebP. The modern
  # `keep` flags strip reliably; `keep: []` keeps nothing. The store test
  # asserts the absence of EXIF fields so a regression fails loudly.
  defp write_webp(image, dest) do
    case Vix.Vips.Operation.webpsave(image, dest, keep: [], Q: @quality) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Absolute on-disk path of a *served* version (`"thumb" | "feed" | "large"`),
  or `nil` when the file is missing. Never resolves the original.
  """
  def version_path(%PostImage{token: token}, version) do
    if version in PostImage.versions() do
      path = Path.join(dir(token), "#{version}.webp")
      if File.exists?(path), do: path
    end
  end

  @doc """
  The path nginx resolves inside its `internal` alias location
  (production X-Accel-Redirect target).
  """
  def accel_path(%PostImage{token: token}, version) when is_binary(version) do
    "/internal_post_images/#{token}/#{version}.webp"
  end

  @doc "Removes every stored file of `token`. A no-op when nothing is stored."
  def delete(token) when is_binary(token) do
    File.rm_rf(dir(token))
    :ok
  end

  defp dir(token) do
    # The token is Base64-URL ([A-Za-z0-9_-]) by construction, but never
    # trust a stored value enough to build paths with separators in it.
    false = String.contains?(token, ["/", ".."])
    Vutuv.Uploads.disk_dir(Path.join("post_images", token))
  end
end
