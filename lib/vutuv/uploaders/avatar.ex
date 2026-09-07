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

  alias Vutuv.Images
  alias Vutuv.LowBandwidth
  alias Vutuv.Uploads
  alias Vutuv.Uploads.Crop
  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @config %{
    spec_key: :avatar,
    prefix: "avatars",
    # This image's kind in the shared `images` table (`Vutuv.Images`), declared
    # rather than derived from `spec_key`: the two strings coincide today and
    # nothing says they must.
    kind: "avatar",
    default_version: :medium,
    # The member-row column a re-derive writes the fresh fingerprint back into.
    # A **write**: since #2027 the fingerprint every URL is built from is read
    # off the `images` row, and this column only stays in step until the deploy
    # that drops it. See `Vutuv.Uploads.regenerate/3`.
    fingerprint_field: :avatar_fingerprint,
    # The AI gate screens this kind, so a fresh upload's bytes go to the
    # quarantine tree until it rules (`Vutuv.Moderation.ImageScans`).
    moderated: true
  }

  @default_avatar ~s"data:image/svg+xml,%3Csvg%20width%3D%27200%27%20height%3D%27200%27%20xmlns%3D%27http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%27%20xmlns%3Axlink%3D%27http%3A%2F%2Fwww.w3.org%2F1999%2Fxlink%27%3E%3Cdefs%3E%3Ccircle%20id%3D%27a%27%20cx%3D%27100%27%20cy%3D%27100%27%20r%3D%27100%27%2F%3E%3C%2Fdefs%3E%3Cg%20fill%3D%27none%27%20fill-rule%3D%27evenodd%27%3E%3Cmask%20id%3D%27b%27%20fill%3D%27%23fff%27%3E%3Cuse%20xlink%3Ahref%3D%27%23a%27%2F%3E%3C%2Fmask%3E%3Cuse%20fill%3D%27%23EEE%27%20xlink%3Ahref%3D%27%23a%27%2F%3E%3Cpath%20d%3D%27M88.96%20154c-6.357-12.418-12.81-26.952-19.355-43.597C63.06%2093.76%2056.858%2075.626%2051%2056h29.437c1.247%204.844%202.714%2010.093%204.4%2015.743%201.682%205.653%203.428%2011.365%205.24%2017.143%201.808%205.772%203.615%2011.394%205.425%2016.86%201.81%205.466%203.59%2010.434%205.336%2014.904%201.618-4.47%203.365-9.438%205.234-14.905%201.87-5.465%203.71-11.087%205.518-16.86%201.807-5.777%203.554-11.49%205.237-17.142%201.682-5.65%203.15-10.9%204.395-15.743h28.71c-5.857%2019.626-12.055%2037.76-18.594%2054.403C124.8%20127.048%20118.352%20141.583%20112%20154H88.96z%27%20fill%3D%27%231A1918%27%20opacity%3D%27.1%27%20mask%3D%27url(%23b)%27%2F%3E%3C%2Fg%3E%3C%2Fsvg%3E"

  @doc """
  Stores every avatar version for `{upload, user}`, cropping the served
  versions to `crop` (a `"x,y,w,h"` string or `nil` for the centered default;
  see `Vutuv.Uploads.Crop`) and returns
  `{:ok, original_file_name, fingerprint, moderation}` (kept in the `:avatar` /
  `:avatar_fingerprint` / `:avatar_moderation` columns; the crop is folded into
  the fingerprint), or `{:error, :invalid_file}` when the
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
    Uploads.regenerate(pair(user), opts, @config)
  end

  @doc """
  Re-derives the avatar under the user's current handle after a username change
  (the handle is baked into the served filename). See
  `Vutuv.Uploads.reslug/2` and `Accounts.update_username/2`.
  """
  def reslug(user), do: Uploads.reslug(pair(user), @config)

  @doc """
  Releases an approved avatar from the quarantine tree into the served tree —
  see `Vutuv.Uploads.promote_from_quarantine/2`. Called by the moderation
  verdict (`Vutuv.Moderation.ImageSubjects`).
  """
  def promote_from_quarantine(user),
    do: Uploads.promote_from_quarantine(pair(user), @config)

  @doc """
  Moves every avatar file of `user` into the takedown hold of `image_id`, and
  back — the off switch of a copyright freeze (`Vutuv.Images.freeze/1`, issue
  #2012). See `Vutuv.Uploads.hold/3`.
  """
  def hold(image_id, user), do: Uploads.hold(image_id, user, @config)

  def release(image_id, user), do: Uploads.release(image_id, user, @config)

  @doc """
  The quarantined version's on-disk path while the avatar waits in moderation
  limbo — the owner-only preview (`VutuvWeb.PendingImageController`).
  """
  def pending_preview_path(user, version \\ @config.default_version) do
    Uploads.quarantine_version_path(pair(user), version, @config)
  end

  @doc """
  The served version's on-disk path, or `nil` when the file the row names is
  not there. Whichever of the three naming schemes the row is on
  (`Vutuv.Uploads.version_path/3` resolves them). What
  `Vutuv.Images.Backfill.check/1` asks before the contract cut.
  """
  def stored_path(user, version \\ @config.default_version) do
    Uploads.version_path(pair(user), version, @config)
  end

  @doc """
  Removes the legacy avatar files once the row is on the fingerprinted scheme —
  the contract half of the migration. See `Vutuv.Uploads.sweep_legacy/3` and
  `mix vutuv.images.sweep_legacy`.
  """
  def sweep_legacy(user, opts \\ []),
    do: Uploads.sweep_legacy(pair(user), opts, @config)

  @doc """
  Root-relative, URI-encoded URL of this member's avatar at that version, or
  `nil` when there is nothing a reader may fetch: no avatar, one the AI gate
  still holds, one a copyright case froze, or `:original` (the private original
  is never URL-addressable).

  The one function that owns this URL, and since #2027 it is built from the
  picture's row in the shared `images` table — the member row's four columns are
  still written, but nothing reads them.
  """
  def url(user, version \\ @config.default_version) do
    Uploads.url(pair(user), version, @config)
  end

  @doc """
  URL of the enlarged picture behind the profile header's click-to-enlarge
  (issue #1528), or `nil` when there is nothing bigger to open.

  Unlike `url/2` this **checks the disk**, because the `:large` version is
  younger than the rows: an existing avatar only gets the file once
  `Vutuv.Uploads.Regenerator` has re-derived it (the deploy runs that after the
  traffic switch, so there is a window of minutes; a row whose original went
  missing never gets it at all). Answering `nil` there costs one `File.exists?`
  per profile render and buys the alternative to a two-deploy rollout: the
  avatar is simply not clickable yet, instead of being a link to a 404.
  """
  def large_url(user), do: on_disk_url(image(user), user, :large)

  # The served URL of `version`, or nil while its file is not on disk — the
  # answer both younger-than-the-rows versions need. Takes the already-resolved
  # row, so a caller wanting two answers about one picture resolves it once.
  defp on_disk_url(image, user, version) do
    if Uploads.version_path({image, user}, version, @config),
      do: Uploads.url({image, user}, version, @config)
  end

  # This member's avatar row: the preload when a caller remembered one, one
  # primary-key lookup on the member row's pointer when nobody did, and no
  # query at all for a member without a picture.
  defp image(user), do: Images.member_image(user, @config.kind)

  # What the shared pipeline takes: the row beside the member it belongs to.
  defp pair(user), do: {image(user), user}

  @doc """
  Removes the user's avatar files — the served versions and the private
  original. A no-op when none. Called when an account is deleted.
  """
  def delete(user), do: Uploads.delete(user, @config)

  @doc """
  The value templates put in an `<img src>`: the nginx-served URL when the user
  has an avatar, otherwise the default avatar (an inline SVG data URI). An
  avatar in moderation limbo renders as the default for everyone — the
  owner's own preview is a separate, authenticated route.
  """
  def display_url(user, version), do: src(user, version) || @default_avatar

  @doc """
  What an `<img src>` gets for this member at that version, or `nil` when the
  member has **no picture at all** — the answer `VutuvWeb.UI.avatar/1` needs to
  draw its initials tile instead of the anonymous grey silhouette.

  A picture that is only *held* is not "no picture": one the AI gate has in
  quarantine renders the silhouette, as it always did. A picture a copyright
  case froze **is** this case, because a takedown has to read the way a member
  who never uploaded one reads — which is what clearing the member row's four
  columns used to do (issue #2012). Both distinctions come out of one lookup,
  which is why the caller asks this rather than pairing `url/2` with a
  separate "has a picture?" question.
  """
  def src(user, version \\ @config.default_version) do
    with %Images.Image{} = image <- shown(user), do: shown_src(image, user, version)
  end

  @doc """
  What the profile picture at the top of a profile loads for this viewer
  (`VutuvWeb.UI.picture/1`): the 192 px `:medium` as `:src`, and as `:lite`
  the 96 px `:thumb` while the viewer is in data-saving mode
  (`Vutuv.LowBandwidth`) and the file is on disk. That slot is 96 CSS px and
  loads 192 px for HiDPI screens, so the thumb is the same picture at 1x — a
  third of the bytes, and the switch offers the sharp one. Which slot asks is
  `VutuvWeb.UI.avatar/1`'s decision, and it asks only for the 96 px one: every
  other slot loads the thumb already and has nothing cheaper to offer, so it
  takes `src/2` and gets no switch. Asks the disk like `Vutuv.Cover.picture/1`:
  a version named without looking is exactly the broken-picture case the lite
  rule rules out. `:src` is `nil` for a member with no picture, like `src/2`.
  """
  def picture(user) do
    case shown(user) do
      nil ->
        %{src: nil, lite: nil}

      image ->
        LowBandwidth.picture(
          shown_src(image, user, @config.default_version),
          fn -> on_disk_url(image, user, :thumb) end
        )
    end
  end

  # The picture a reader is even told exists: no row, or a frozen one, is "no
  # picture", and the caller draws its initials tile.
  defp shown(user), do: Images.shown_image(user, @config.kind)

  # The URL of a picture that exists, falling back to the silhouette for one
  # nobody may see right now.
  defp shown_src(image, user, version),
    do: Uploads.url({image, user}, version, @config) || @default_avatar

  @doc """
  The avatar as a base64 JPEG `data:` URI (used by the vCard export — contact
  apps cannot display AVIF), derived on the fly from the private original at
  the requested version's dimensions. Falls back to the default inline SVG
  when the user has no avatar / the original is missing.
  """
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
  def og_jpeg(user), do: derive_jpeg(user, @og_size, @og_size, :center)

  # JPEG from the best available source, through the shared `Spec.og_jpeg/2`
  # (which owns the decode, the EXIF autorotation and the stripped save); the
  # shape here is the member's own crop plus the crop-resize.
  #
  # The crop is applied only when deriving from the **original**; a served
  # version fallback (legacy uploads with no kept original) is already cropped,
  # so re-applying the fractions would double-crop it.
  # `Vutuv.Images.servable?/1` is the gate, the same one every URL builder asks:
  # neither the vCard's photo nor the link-preview JPEG may reach past a picture
  # the AI gate is holding, or one a copyright case froze, into the private
  # original.
  defp derive_jpeg(user, width, height, gravity) do
    with %Images.Image{} = image <- image(user),
         true <- Images.servable?(image),
         {origin, path} <- source(image, user) do
      crop = if origin == :original, do: Crop.parse(image.crop)

      Spec.og_jpeg(path, &crop_and_resize(&1, crop, width, height, gravity))
    else
      _ -> :error
    end
  end

  defp crop_and_resize(rotated, crop, width, height, gravity) do
    with {:ok, cropped} <- Crop.apply_to(rotated, crop) do
      Image.thumbnail(cropped, "#{width}x#{height}", crop: gravity)
    end
  end

  defp source(image, user) do
    case Originals.path("#{@config.prefix}/#{user.id}") do
      nil ->
        case Uploads.version_path({image, user}, :medium, @config) do
          nil -> nil
          path -> {:served, path}
        end

      path ->
        {:original, path}
    end
  end
end
