defmodule Vutuv.Cover do
  @moduledoc """
  Profile cover-photo storage and URL generation.

  The wide banner behind the avatar at the top of the profile page. Mirrors
  `Vutuv.Avatar` (explicit local-disk storage + libvips, versions from
  `Vutuv.Uploads.Spec`), but stores a single wide version instead of square
  crops, because the banner is displayed full-bleed with CSS `object-cover`:

      <uploads_dir_prefix>/covers/<user.id>/<First Last>_wide.avif
      <uploads_dir_prefix>/originals/covers/<user.id>/original<ext>

  The served version is AVIF in the public tree (nginx `location /covers/`,
  mirroring `/avatars/`; locally the endpoint serves it when
  `:serve_uploads_locally` is set). The uploaded original is kept verbatim in
  the private `originals/` tree (`Vutuv.Uploads.Originals`) and never served.
  URLs are root-relative (`/covers/<id>/...`) and URI-encoded; pre-AVIF
  derived files keep resolving through a transitional fallback in `url/2`
  until the one-shot regeneration has converted them.
  """

  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @extension_whitelist ~w(.jpg .jpeg .png)

  @doc """
  Stores every cover version for `{upload, user}` and returns
  `{:ok, original_file_name}` (kept verbatim in the `:cover_photo` column), or
  `{:error, :invalid_file}` when the extension is not whitelisted or the file
  cannot be decoded as an image.
  """
  def store({%Plug.Upload{} = upload, scope}) do
    if valid_extension?(upload.filename) do
      ext = Path.extname(upload.filename)
      dir = disk_dir(scope)
      File.mkdir_p!(dir)

      case write_versions(upload, scope, ext, dir) do
        :ok -> {:ok, upload.filename}
        {:error, _reason} -> {:error, :invalid_file}
      end
    else
      {:error, :invalid_file}
    end
  end

  # The derived versions go first: they decode the image, so a corrupt or
  # truncated file fails before anything is written; the original is only
  # copied (privately) after a successful decode.
  defp write_versions(upload, scope, ext, dir) do
    with {:ok, rotated} <- Spec.open_rotated(upload.path),
         :ok <- write_derived_versions(rotated, scope, dir) do
      Originals.store(storage_dir(scope), upload.path, ext)
    end
  end

  defp write_derived_versions(rotated, scope, dir) do
    Enum.reduce_while(Spec.versions(:cover), :ok, fn spec, :ok ->
      dest = Path.join(dir, version_filename(scope, spec.name, Spec.served_ext()))

      case Spec.write_derived(spec, rotated, dest) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Re-derives the served version from the original per the current
  `Vutuv.Uploads.Spec` — see `Vutuv.Uploads.regenerate_from_original/3`,
  which this configures with the cover layout. Used by
  `Vutuv.Uploads.Regenerator`.
  """
  def regenerate(user, opts \\ []) do
    dir = disk_dir(user)

    Vutuv.Uploads.regenerate_from_original(storage_dir(user), dir,
      canonical: canonical_filenames(user),
      stale_glob: "*_{wide,original}.*",
      legacy_candidates: [Path.join(dir, "*_original.*")],
      derive: &write_derived_versions(&1, user, dir),
      opts: opts
    )
  end

  defp canonical_filenames(scope) do
    for spec <- Spec.versions(:cover),
        do: version_filename(scope, spec.name, Spec.served_ext())
  end

  @doc """
  Root-relative, URI-encoded URL for a given `{cover_photo, user}` and served
  version. Returns `nil` when the user has no cover photo or for `:original`
  (the original is never URL-addressable).
  """
  def url(file_and_scope, version \\ :wide)
  def url({nil, _scope}, _version), do: nil
  def url({_cover, _scope}, :original), do: nil

  def url({cover, scope}, version) do
    local_path = Path.join(storage_dir(scope), served_filename(scope, version, cover))

    "/"
    |> Path.join(local_path)
    |> URI.encode()
  end

  @doc """
  The value templates put in an `<img src>`, or `nil` when the user has no cover
  photo (so the caller can fall back to the gradient banner).
  """
  def display_url(%{cover_photo: nil}, _version), do: nil
  def display_url(user, version), do: url({user.cover_photo, user}, version)

  # The .avif is authoritative; until the regeneration has run, a pre-AVIF
  # derived file with the stored filename's extension keeps resolving.
  # Transitional — remove together with `Spec.legacy_exts/0`.
  defp served_filename(scope, version, cover) do
    avif = version_filename(scope, version, Spec.served_ext())

    if File.exists?(Path.join(disk_dir(scope), avif)) do
      avif
    else
      legacy_filename(scope, version, cover) || avif
    end
  end

  defp legacy_filename(scope, version, cover) do
    candidate = version_filename(scope, version, extname(cover))
    if File.exists?(Path.join(disk_dir(scope), candidate)), do: candidate
  end

  defp storage_dir(scope), do: "covers/#{scope.id}"

  defp disk_dir(scope), do: Vutuv.Uploads.disk_dir(storage_dir(scope))

  defp version_filename(scope, version, ext), do: "#{scope}_#{version}#{ext}"

  defp extname(value) when is_binary(value) do
    value
    |> Vutuv.Uploads.strip_query()
    |> Path.extname()
  end

  defp valid_extension?(file_name) do
    extension = file_name |> Path.extname() |> String.downcase()
    extension in @extension_whitelist
  end
end
