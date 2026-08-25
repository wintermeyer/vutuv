defmodule Vutuv.OrganizationImageStore do
  @moduledoc """
  On-disk storage for organization images (the logo/cover columns and the
  description-editor images) — the `Vutuv.PostImageStore` pattern 1:1. There is
  no public tree: every served byte goes through the authorizing proxy
  (`VutuvWeb.OrganizationImageController`), keyed by an unguessable token that is
  also the on-disk directory name.

      <uploads_dir_prefix>/organization_images/<token>/thumb.avif /feed.avif /large.avif
      <uploads_dir_prefix>/originals/organization_images/<token>/original.<ext>

  Resolution/format/quality of the served versions come from
  `Vutuv.Uploads.Spec` (reusing the `:post_image` spec: AVIF, autorotated then
  metadata-stripped). The extension whitelist (incl. capability-detected HEIC)
  is shared with `Vutuv.PostImageStore`.
  """

  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @versions ~w(thumb feed large)
  @og_size 512

  defdelegate extension_whitelist, to: Vutuv.PostImageStore

  @doc """
  Stores every version of the file at `path` under a fresh `token` directory and
  returns `{:ok, %{width:, height:, content_type:, size_bytes:}}` (dimensions are
  post-rotation) or `{:error, :invalid_file}`.
  """
  def store(path, filename, token) do
    dir = dir(token)

    Vutuv.Uploads.store_upload(filename, extension_whitelist(), dir, fn ext ->
      write_versions(path, ext, dir, token)
    end)
  end

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

  # `:organization_image`, not `:post_image`. The post list carries a fourth,
  # 2560px `xl` version for the lightbox; nothing here can ever serve it —
  # `@versions`, and with it the proxy's whitelist, `version_path/2` and
  # `accel_path/2`, know only three names. So every logo, cover and gallery
  # shot paid for the most expensive AVIF encode of the four and kept the file
  # for ever, unreachable.
  defp write_derived_versions(rotated, dir) do
    Spec.write_all(:organization_image, rotated, fn spec ->
      Path.join(dir, "#{spec.name}#{Spec.served_ext()}")
    end)
  end

  @doc """
  Re-derives every served version from the kept original (for the Regenerator).

  This tree had no such hook at all, so a format or quality change in
  `Vutuv.Uploads.Spec` never reached a single organization logo, cover or
  gallery picture — while the Regenerator's own doc calls itself "the tool that
  makes a Spec change real for existing data" and reported success.
  """
  def regenerate(token, opts \\ []) when is_binary(token) do
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
    for spec <- Spec.versions(:organization_image), do: "#{spec.name}#{Spec.served_ext()}"
  end

  @doc "The served version names (drives the proxy's URL whitelist)."
  def versions, do: @versions

  @doc "Absolute on-disk path of a served version, or `nil` when missing."
  def version_path(token, version) when is_binary(token) and version in @versions do
    avif = Path.join(dir(token), "#{version}#{Spec.served_ext()}")
    if File.exists?(avif), do: avif
  end

  def version_path(_, _), do: nil

  @doc "The production X-Accel-Redirect target for a served version."
  def accel_path(token, version) when is_binary(token) and version in @versions do
    "/internal_organization_images/#{token}/#{version}#{Spec.served_ext()}"
  end

  @doc """
  A stored image as JPEG bytes for `/organizations/:slug/avatar.jpg`
  (`VutuvWeb.OrganizationAvatarController`): the `icon` of a page's ActivityPub
  actor document, and whatever else fetches a picture from outside. Neither a
  remote server nor a link-preview scraper decodes the AVIF versions served
  above, so the JPEG is derived on the fly from the kept private original,
  metadata-stripped, at #{@og_size}px square — `Vutuv.Avatar.og_jpeg/1` for a
  page instead of a member.

  There is no served-version fallback: unlike avatars, organization images have
  kept an original since the day the store existed, so a token with no original
  has nothing on disk at all. `:error` then, and for an unknown token.

  Who may see it is the caller's decision (`Organizations.image_visible_to?/2`
  and the page's own visibility); this only answers whether bytes exist.
  """
  def og_jpeg(token) when is_binary(token) do
    case original_path(token) do
      nil ->
        :error

      path ->
        Spec.og_jpeg(path, &Image.thumbnail(&1, "#{@og_size}x#{@og_size}", crop: :center))
    end
  end

  def og_jpeg(_), do: :error

  @doc "Absolute path of the kept private original, or `nil` when there is none."
  def original_path(token) when is_binary(token), do: Originals.path(storage_dir(token))
  def original_path(_), do: nil

  @doc "Removes every stored file of `token`. A no-op when nothing is stored."
  def delete(token) when is_binary(token) do
    File.rm_rf(dir(token))
    Originals.delete(storage_dir(token))
    :ok
  end

  def delete(_), do: :ok

  defp storage_dir(token) do
    # The token is Base64-URL ([A-Za-z0-9_-]) by construction, but never trust a
    # stored value enough to build paths with separators in it.
    false = String.contains?(token, ["/", ".."])
    Path.join("organization_images", token)
  end

  defp dir(token), do: Vutuv.Uploads.disk_dir(storage_dir(token))
end
