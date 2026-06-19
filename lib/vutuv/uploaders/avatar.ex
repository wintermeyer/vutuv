defmodule Vutuv.Avatar do
  @moduledoc """
  Avatar storage and URL generation.

  Explicit local-disk storage with libvips; resolution, format and quality of
  the served versions come from `Vutuv.Uploads.Spec`. The derived versions are
  AVIF and live in the publicly served tree (nginx `location /avatars/`), named
  for the owner's handle and the image's content fingerprint, so a download
  carries the username and the URL is immutable (no `?v=` cache-buster):

      <uploads_dir_prefix>/avatars/<user.id>/<username>-<version>-<fingerprint>.avif

  The fingerprint (`sha256(original)[0..11]`) is stored in `:avatar_fingerprint`;
  the on-disk filename equals the URL's last segment, so the existing nginx
  `alias` serves it directly (no rewrite). A row with no fingerprint has not been
  migrated to this scheme yet and falls back to the legacy
  `avatar_<version>.avif?v=...` URL (see `Vutuv.Uploads`); a username change
  re-derives the files under the new handle (`reslug/1`).

  The uploaded **original** is kept verbatim (format + metadata) so better
  formats can be re-derived later (`Vutuv.Uploads.Regenerator`), but in a
  private tree that is never served — nobody can download the full-resolution
  upload:

      <uploads_dir_prefix>/originals/avatars/<user.id>/original<ext>

  `uploads_dir_prefix` is the absolute storage root, configured per environment
  (`config :vutuv, :uploads_dir_prefix`); it is empty in dev/test and
  `/srv/legacy-vutuv` in production. URLs are always root-relative
  (`/avatars/<id>/...`) and URI-encoded.

  The store/serve/url/regenerate pipeline is shared with `Vutuv.Cover` and
  lives in `Vutuv.Uploads`; this module supplies the avatar layout (`@config`)
  and the avatar-only extras: the default inline-SVG fallback, `binary/2` for
  the vCard export and `user_url/2`.
  """

  alias Vix.Vips.Operation
  alias Vutuv.Uploads
  alias Vutuv.Uploads.Crop
  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @config %{
    spec_key: :avatar,
    prefix: "avatars",
    default_version: :medium,
    # The user column holding this image's content fingerprint. When set, the
    # served filename embeds the handle + fingerprint (`<username>-<version>-<fp>.avif`)
    # and the URL needs no `?v=`; when nil the row predates the scheme and falls
    # back to the legacy URL. See Vutuv.Uploads.served_url/4.
    fingerprint_field: :avatar_fingerprint,
    # Everything version-shaped a past pipeline may have left: old-extension
    # versions, publicly stored originals, files named for a previous user
    # name, and the Waffle-era `_large` (512px) the current code never serves.
    stale_glob: "*_*.*",
    crop_field: :avatar_crop
  }

  @default_avatar ~s"data:image/svg+xml,%3Csvg%20width%3D%27200%27%20height%3D%27200%27%20xmlns%3D%27http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%27%20xmlns%3Axlink%3D%27http%3A%2F%2Fwww.w3.org%2F1999%2Fxlink%27%3E%3Cdefs%3E%3Ccircle%20id%3D%27a%27%20cx%3D%27100%27%20cy%3D%27100%27%20r%3D%27100%27%2F%3E%3C%2Fdefs%3E%3Cg%20fill%3D%27none%27%20fill-rule%3D%27evenodd%27%3E%3Cmask%20id%3D%27b%27%20fill%3D%27%23fff%27%3E%3Cuse%20xlink%3Ahref%3D%27%23a%27%2F%3E%3C%2Fmask%3E%3Cuse%20fill%3D%27%23EEE%27%20xlink%3Ahref%3D%27%23a%27%2F%3E%3Cpath%20d%3D%27M88.96%20154c-6.357-12.418-12.81-26.952-19.355-43.597C63.06%2093.76%2056.858%2075.626%2051%2056h29.437c1.247%204.844%202.714%2010.093%204.4%2015.743%201.682%205.653%203.428%2011.365%205.24%2017.143%201.808%205.772%203.615%2011.394%205.425%2016.86%201.81%205.466%203.59%2010.434%205.336%2014.904%201.618-4.47%203.365-9.438%205.234-14.905%201.87-5.465%203.71-11.087%205.518-16.86%201.807-5.777%203.554-11.49%205.237-17.142%201.682-5.65%203.15-10.9%204.395-15.743h28.71c-5.857%2019.626-12.055%2037.76-18.594%2054.403C124.8%20127.048%20118.352%20141.583%20112%20154H88.96z%27%20fill%3D%27%231A1918%27%20opacity%3D%27.1%27%20mask%3D%27url(%23b)%27%2F%3E%3C%2Fg%3E%3C%2Fsvg%3E"

  @doc """
  Stores every avatar version for `{upload, user}`, cropping the served
  versions to `crop` (a `"x,y,w,h"` string or `nil` for the centered default;
  see `Vutuv.Uploads.Crop`) and returns `{:ok, original_file_name, fingerprint}`
  (kept in the `:avatar` / `:avatar_fingerprint` columns; the crop is folded
  into the fingerprint), or `{:error, :invalid_file}` when the
  extension is not whitelisted **or the file cannot be decoded as an image**
  (corrupt/truncated uploads used to crash the request with a `MatchError`).
  """
  def store({%Plug.Upload{}, _scope} = upload_and_scope, crop \\ nil) do
    Uploads.store(upload_and_scope, @config, crop)
  end

  @doc """
  Migrates the avatar to the fingerprinted scheme, or re-derives a row already
  on it, per the current `Vutuv.Uploads.Spec` — see `Vutuv.Uploads.regenerate/3`,
  which this configures with the avatar layout. Used by
  `Vutuv.Uploads.Regenerator`.
  """
  def regenerate(user, opts \\ []) do
    Uploads.regenerate(user, opts, @config)
  end

  @doc """
  Re-derives the avatar under the user's current handle after a username change
  (the handle is baked into the served filename). See
  `Vutuv.Uploads.reslug/2` and `Accounts.update_username/2`.
  """
  def reslug(user), do: Uploads.reslug(user, @config)

  @doc """
  Removes the legacy avatar files once the row is on the fingerprinted scheme —
  the contract half of the migration. See `Vutuv.Uploads.sweep_legacy/3` and
  `mix vutuv.images.sweep_legacy`.
  """
  def sweep_legacy(user, opts \\ []), do: Uploads.sweep_legacy(user, opts, @config)

  @doc """
  Root-relative, URI-encoded URL for a given `{avatar, user}` and served
  version. Returns `nil` when the user has no avatar or for `:original`
  (the original is never URL-addressable).
  """
  def url(file_and_scope, version \\ @config.default_version) do
    Uploads.url(file_and_scope, version, @config)
  end

  def user_url(user, version) do
    Vutuv.Avatar.url({user.avatar, user}, version)
  end

  @doc """
  Removes the user's avatar files — the served versions and the private
  original. A no-op when none. Called when an account is deleted.
  """
  def delete(user), do: Uploads.delete(user, @config)

  @doc """
  The value templates put in an `<img src>`: the nginx-served URL when the user
  has an avatar, otherwise the default avatar (an inline SVG data URI).
  """
  def display_url(%{avatar: nil}, _version), do: @default_avatar
  def display_url(user, version), do: url({user.avatar, user}, version)

  @doc """
  The avatar as a base64 JPEG `data:` URI (used by the vCard export — contact
  apps cannot display AVIF), derived on the fly from the private original at
  the requested version's dimensions. Falls back to the default inline SVG
  when the user has no avatar / the original is missing.
  """
  def binary(%{avatar: nil}, _version), do: @default_avatar

  def binary(user, version) do
    %{fit: {:crop, width, height, gravity}} = Spec.version(:avatar, version)

    case derive_jpeg(user, width, height, gravity) do
      {:ok, data} -> "data:image/jpeg;base64,#{Base.encode64(data)}"
      :error -> @default_avatar
    end
  end

  @og_size 512

  @doc "The pixel size (square) of the link-preview JPEG from `og_jpeg/1`."
  def og_size, do: @og_size

  @doc """
  The avatar as JPEG bytes for the link-preview endpoint
  (`/:slug/avatar.jpg`, see `VutuvWeb.AvatarController`): Open Graph
  scrapers don't decode the served AVIF versions. Derived on the fly from
  the private original — or, for legacy uploads that predate the kept
  originals, from the largest served version — at #{@og_size}px square.
  `:error` when the user has no avatar or nothing usable is on disk.
  """
  def og_jpeg(%{avatar: nil}), do: :error
  def og_jpeg(user), do: derive_jpeg(user, @og_size, @og_size, :center)

  # JPEG from the best available source: decode + EXIF-autorotate, apply the
  # user's crop, crop-resize, save **stripped** (`keep: []`). The original's
  # metadata (camera, GPS) must never leak into a served or exported
  # derivative — the same rule the AVIF pipeline enforces in Vutuv.Uploads.Spec.
  #
  # The crop is applied only when deriving from the **original**; a served
  # version fallback (legacy uploads with no kept original) is already cropped,
  # so re-applying the fractions would double-crop it.
  defp derive_jpeg(user, width, height, gravity) do
    case source(user) do
      nil ->
        :error

      {origin, path} ->
        crop = if origin == :original, do: Crop.parse(Map.get(user, :avatar_crop))

        with {:ok, rotated} <- Spec.open_rotated(path),
             {:ok, cropped} <- Crop.apply_to(rotated, crop),
             {:ok, small} <- Image.thumbnail(cropped, "#{width}x#{height}", crop: gravity),
             {:ok, data} <- Operation.jpegsave_buffer(small, keep: [], Q: 80) do
          {:ok, data}
        else
          _ -> :error
        end
    end
  end

  defp source(user) do
    case Originals.path("#{@config.prefix}/#{user.id}") do
      nil ->
        case Uploads.version_path({user.avatar, user}, :medium, @config) do
          nil -> nil
          path -> {:served, path}
        end

      path ->
        {:original, path}
    end
  end
end
