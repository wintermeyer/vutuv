defmodule Vutuv.Cover do
  @moduledoc """
  Profile cover-photo storage and URL generation.

  The wide banner behind the avatar at the top of the profile page. Mirrors
  `Vutuv.Avatar` (explicit local-disk storage + libvips, versions from
  `Vutuv.Uploads.Spec`), but stores a single wide version instead of square
  crops, because the banner is displayed full-bleed with CSS `object-cover`:

      <uploads_dir_prefix>/covers/<user.id>/cover_wide.avif
      <uploads_dir_prefix>/originals/covers/<user.id>/original<ext>

  The served version is AVIF in the public tree (nginx `location /covers/`,
  mirroring `/avatars/`; locally the endpoint serves it when
  `:serve_uploads_locally` is set). The uploaded original is kept verbatim in
  the private `originals/` tree (`Vutuv.Uploads.Originals`) and never served.
  URLs are root-relative (`/covers/<id>/...`) and URI-encoded; files from an
  earlier pipeline (pre-AVIF, or the pre-#773 name-derived `<First Last>_wide`)
  keep resolving through a transitional fallback until the one-shot
  regeneration has re-derived them under the stable name.

  The store/serve/url/regenerate pipeline is shared with `Vutuv.Avatar` and
  lives in `Vutuv.Uploads`; this module supplies only the cover layout
  (`@config`).
  """

  alias Vutuv.Uploads

  @config %{
    spec_key: :cover,
    prefix: "covers",
    default_version: :wide,
    stale_glob: "*_{wide,original}.*"
  }

  @doc """
  Stores every cover version for `{upload, user}` and returns
  `{:ok, original_file_name}` (kept verbatim in the `:cover_photo` column), or
  `{:error, :invalid_file}` when the extension is not whitelisted or the file
  cannot be decoded as an image.
  """
  def store({%Plug.Upload{}, _scope} = upload_and_scope) do
    Uploads.store(upload_and_scope, @config)
  end

  @doc """
  Re-derives the served version from the original per the current
  `Vutuv.Uploads.Spec` — see `Vutuv.Uploads.regenerate_from_original/3`,
  which this configures with the cover layout. Used by
  `Vutuv.Uploads.Regenerator`.
  """
  def regenerate(user, opts \\ []) do
    Uploads.regenerate(user, opts, @config)
  end

  @doc """
  Root-relative, URI-encoded URL for a given `{cover_photo, user}` and served
  version. Returns `nil` when the user has no cover photo or for `:original`
  (the original is never URL-addressable).
  """
  def url(file_and_scope, version \\ @config.default_version) do
    Uploads.url(file_and_scope, version, @config)
  end

  @doc """
  The value templates put in an `<img src>`, or `nil` when the user has no cover
  photo (so the caller can fall back to the gradient banner).
  """
  def display_url(%{cover_photo: nil}, _version), do: nil
  def display_url(user, version), do: url({user.cover_photo, user}, version)

  @doc """
  Removes the user's cover-photo files — the served version and the private
  original. A no-op when none. Called when an account is deleted.
  """
  def delete(user), do: Uploads.delete(user, @config)
end
