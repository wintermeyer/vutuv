defmodule Vutuv.Posts.PostImage do
  @moduledoc """
  An image belonging to a post (or, while composing, to a user).

  Images are uploaded eagerly — the composer needs a URL before the post
  exists so the author can reference the image inline (`![](url)`) — so
  `post_id` stays `nil` until the post is submitted. Unattached rows older
  than a day are swept (`Vutuv.Posts.sweep_pending_images/0`).

  All derived versions (`thumb`/`feed`/`large`/`xl`) are metadata-stripped
  AVIF (`Vutuv.Uploads.Spec`); the original keeps its metadata in the private
  `originals/` tree. Serving always goes through the authorizing proxy
  (`/post_images/:token/:version`) — `token` is the lookup key and on-disk
  directory name, never the row id.

  ## Photo posts (issue #1104)

  Three things a photographer needs ride on the row itself:

    * **`caption`** — shown under the photo to everyone. Distinct from `alt`,
      which describes the picture for people who cannot see it; a caption that
      reads "Shot on the last morning in Lisbon" is not a description, and an
      alt text spelled out for a screen reader is not a caption.

    * **the camera facts** (`camera`/`lens`/`focal_length`/`aperture`/
      `shutter`/`iso`/`taken_at`) — parsed once at upload by
      `Vutuv.Uploads.Exif` and rendered from these columns, never from the
      delivered file, which stays metadata-stripped. Shown only when the
      author switched `show_camera_info` on.

    * **the original download** (`download_original`, `download_exact`) — off
      by default. On, the lightbox offers the full-resolution file: either
      the cleaned copy (all metadata removed, pixels untouched — the default)
      or the byte-identical upload.

  `has_gps` records only *that* the upload carried a location, so the composer
  can warn before the exact file is handed out. The coordinates are never
  parsed, stored or shown.
  """

  use VutuvWeb, :model

  alias Vutuv.Uploads.Exif
  alias Vutuv.Uploads.Spec

  @versions ~w(thumb feed large xl)

  @max_caption_length 1_000

  schema "post_images" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:user, Vutuv.Accounts.User)

    field(:token, :string)
    field(:alt, :string, default: "")
    field(:caption, :string)
    field(:position, :integer, default: 0)
    field(:width, :integer)
    field(:height, :integer)
    field(:content_type, :string)
    field(:size_bytes, :integer)

    # The author's ratio crop as `"x,y,w,h"` fractions of the EXIF-rotated
    # original (`Vutuv.Uploads.Crop`), written by `Vutuv.Posts.crop_image/2`
    # alongside the re-derive, never cast from user params directly. While it
    # is set, `width`/`height` are the **cropped** dimensions (they describe
    # what is served) and the uncropped picture leaves the server on no path
    # but the author-only crop workbench (`Vutuv.PostImageStore.source_path/1`).
    field(:crop, :string)

    # The whitelisted camera facts (Vutuv.Uploads.Exif), parsed at upload and
    # never cast from user params — they describe the file, not the author's
    # opinion of it.
    field(:camera, :string)
    field(:lens, :string)
    field(:focal_length, :string)
    field(:aperture, :string)
    field(:shutter, :string)
    field(:iso, :integer)
    field(:taken_at, :naive_datetime)
    field(:has_gps, :boolean, default: false)

    # The author's two per-photo choices.
    field(:show_camera_info, :boolean, default: false)
    field(:download_original, :boolean, default: false)
    field(:download_exact, :boolean, default: false)

    # AI image moderation state (Vutuv.Moderation.ImageScans). DB default is
    # "pending", so an image is invisible-to-others until released.
    field(:moderation, :string, default: "pending")

    timestamps()
  end

  def versions, do: @versions
  def max_caption_length, do: @max_caption_length

  def alt_changeset(image, params) do
    image
    |> cast(params, [:alt])
    |> update_change(:alt, &String.trim/1)
    |> validate_length(:alt, max: 255)
  end

  @doc """
  The composer's per-photo panel: the two texts and the two opt-ins.

  `download_exact` is only meaningful while `download_original` is on, so it
  is forced back off when the download is — otherwise a member who turns the
  download off and on again would silently get their earlier "exact file"
  choice back, which is the wrong direction for a setting that hands out
  location data.
  """
  def settings_changeset(image, params) do
    image
    |> cast(params, [
      :alt,
      :caption,
      :show_camera_info,
      :download_original,
      :download_exact
    ])
    |> update_change(:alt, &String.trim/1)
    |> update_change(:caption, &String.trim/1)
    |> validate_length(:alt, max: 255)
    |> validate_length(:caption, max: @max_caption_length)
    |> reset_exact_when_download_off()
  end

  defp reset_exact_when_download_off(changeset) do
    if get_field(changeset, :download_original) do
      changeset
    else
      put_change(changeset, :download_exact, false)
    end
  end

  @doc """
  The camera facts as one line, or `nil` when the photo carries none — the
  single check "is there camera info to show" that the composer's switch, the
  lightbox panel and the agent docs all branch on.
  """
  def camera_summary(%__MODULE__{} = image) do
    Exif.summary(%{
      camera: image.camera,
      lens: image.lens,
      focal_length: image.focal_length,
      aperture: image.aperture,
      shutter: image.shutter,
      iso: image.iso
    })
  end

  @doc "Whether this photo carries any camera facts at all."
  def camera_info?(%__MODULE__{} = image), do: camera_summary(image) != nil

  @doc """
  Whether the camera panel renders for visitors: the author asked for it and
  there is something to put in it.
  """
  def show_camera_info?(%__MODULE__{} = image),
    do: image.show_camera_info and camera_info?(image)

  @doc "A fresh unguessable URL token (~128 bits, URL-safe)."
  def gen_token do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc "Whether the author cropped this photo (the served frame ≠ the upload)."
  def cropped?(%__MODULE__{crop: crop}), do: is_binary(crop) and crop != ""

  @doc "Root-relative proxy URL for a version of this image."
  def url(%__MODULE__{token: token} = image, version) when version in @versions do
    "#{token_prefix(token)}#{version}#{Spec.served_ext()}#{crop_buster(image)}"
  end

  # The proxy serves every version under an immutable-cache header, so a
  # re-crop (which overwrites the files in place) must change the URL or every
  # browser that saw the old frame keeps it for a year. The buster is a short
  # hash of the crop, so the same crop always names the same URL and an
  # uncropped photo keeps its historical bare one.
  defp crop_buster(%__MODULE__{crop: crop}) when is_binary(crop) and crop != "" do
    "?v=" <>
      (:sha256 |> :crypto.hash(crop) |> Base.url_encode64(padding: false) |> binary_part(0, 8))
  end

  defp crop_buster(%__MODULE__{}), do: ""

  @doc """
  Root-relative proxy URL of the **original download**, or `nil` when the
  author did not offer one. The extension is always `.orig` rather than the
  file's own: the proxy resolves the real format from disk and names the
  download in its `Content-Disposition`, so the URL cannot be used to probe
  which format somebody uploaded.
  """
  def download_url(%__MODULE__{download_original: true, token: token} = image),
    do: "#{token_prefix(token)}original.orig#{crop_buster(image)}"

  def download_url(%__MODULE__{}), do: nil

  @doc """
  The link-preview JPEG URL (the post's `og:image`, see
  `VutuvWeb.OpenGraph`) — derived on the fly by the proxy, not a stored
  version (`Vutuv.PostImageStore.og_jpeg/1`).
  """
  def og_url(%__MODULE__{token: token} = image),
    do: "#{token_prefix(token)}og.jpg#{crop_buster(image)}"

  @doc "URLs for every served version as a `%{version => url}` map."
  def urls(%__MODULE__{} = image) do
    Map.new(@versions, fn version -> {String.to_atom(version), url(image, version)} end)
  end

  @doc """
  Every URL form that may reference this version in a stored post body: the
  canonical URL, the bare (buster-less) form a body stored before the photo
  was cropped still carries, plus the pre-AVIF `.webp` form old bodies still
  carry (transitional — remove together with `Vutuv.Uploads.Spec.legacy_exts/0`).
  """
  def url_forms(%__MODULE__{token: token} = image, version) when version in @versions do
    Enum.uniq([
      url(image, version),
      "#{token_prefix(token)}#{version}#{Spec.served_ext()}",
      "#{token_prefix(token)}#{version}.webp"
    ])
  end

  @doc """
  Whether `body` references this image's proxy URL (any version) inline.
  Keeps the URL scheme knowledge next to `url/2` — used to decide which
  attachments render inline vs. in the gallery below the post.
  """
  def referenced_in?(%__MODULE__{token: token}, body) when is_binary(body) do
    String.contains?(body, token_prefix(token))
  end

  @doc """
  The photo's aspect ratio (width / height), or `1.0` when the dimensions are
  missing. What the bento mosaic lays out from
  (`VutuvWeb.PostComponents.mosaic/1`), so a portrait photo lands in a
  portrait cell rather than being cropped into a landscape one.
  """
  def aspect(%__MODULE__{width: width, height: height})
      when is_integer(width) and is_integer(height) and width > 0 and height > 0,
      do: width / height

  def aspect(%__MODULE__{}), do: 1.0

  @doc """
  `:portrait`, `:landscape` or `:square` — the coarse shape the mosaic picks
  its layout from. The 5:4 / 4:5 envelope matches the post card's existing
  "roughly square" rule, so one photo is called the same shape by both.
  """
  def orientation(%__MODULE__{} = image) do
    ratio = aspect(image)

    cond do
      ratio > 1.25 -> :landscape
      ratio < 0.8 -> :portrait
      true -> :square
    end
  end

  defp token_prefix(token), do: "/post_images/#{token}/"
end
