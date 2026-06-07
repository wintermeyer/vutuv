defmodule Vutuv.Avatar do
  @moduledoc """
  Avatar storage and URL generation.

  Explicit local-disk storage with libvips; resolution, format and quality of
  the served versions come from `Vutuv.Uploads.Spec`. The derived versions are
  AVIF and live in the publicly served tree (nginx `location /avatars/`):

      <uploads_dir_prefix>/avatars/<user.id>/<First Last>_<version>.avif

  The uploaded **original** is kept verbatim (format + metadata) so better
  formats can be re-derived later (`Vutuv.Uploads.Regenerator`), but in a
  private tree that is never served — nobody can download the full-resolution
  upload:

      <uploads_dir_prefix>/originals/avatars/<user.id>/original<ext>

  `uploads_dir_prefix` is the absolute storage root, configured per environment
  (`config :vutuv, :uploads_dir_prefix`); it is empty in dev/test and
  `/srv/legacy-vutuv` in production. URLs are always root-relative
  (`/avatars/<id>/...`) and URI-encoded. Pre-AVIF derived files (`_thumb.jpg`)
  keep resolving through a transitional fallback in `url/2` until the one-shot
  regeneration has converted them.
  """

  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @extension_whitelist ~w(.jpg .jpeg .png)
  @default_avatar ~s"data:image/svg+xml,%3Csvg%20width%3D%27200%27%20height%3D%27200%27%20xmlns%3D%27http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%27%20xmlns%3Axlink%3D%27http%3A%2F%2Fwww.w3.org%2F1999%2Fxlink%27%3E%3Cdefs%3E%3Ccircle%20id%3D%27a%27%20cx%3D%27100%27%20cy%3D%27100%27%20r%3D%27100%27%2F%3E%3C%2Fdefs%3E%3Cg%20fill%3D%27none%27%20fill-rule%3D%27evenodd%27%3E%3Cmask%20id%3D%27b%27%20fill%3D%27%23fff%27%3E%3Cuse%20xlink%3Ahref%3D%27%23a%27%2F%3E%3C%2Fmask%3E%3Cuse%20fill%3D%27%23EEE%27%20xlink%3Ahref%3D%27%23a%27%2F%3E%3Cpath%20d%3D%27M88.96%20154c-6.357-12.418-12.81-26.952-19.355-43.597C63.06%2093.76%2056.858%2075.626%2051%2056h29.437c1.247%204.844%202.714%2010.093%204.4%2015.743%201.682%205.653%203.428%2011.365%205.24%2017.143%201.808%205.772%203.615%2011.394%205.425%2016.86%201.81%205.466%203.59%2010.434%205.336%2014.904%201.618-4.47%203.365-9.438%205.234-14.905%201.87-5.465%203.71-11.087%205.518-16.86%201.807-5.777%203.554-11.49%205.237-17.142%201.682-5.65%203.15-10.9%204.395-15.743h28.71c-5.857%2019.626-12.055%2037.76-18.594%2054.403C124.8%20127.048%20118.352%20141.583%20112%20154H88.96z%27%20fill%3D%27%231A1918%27%20opacity%3D%27.1%27%20mask%3D%27url(%23b)%27%2F%3E%3C%2Fg%3E%3C%2Fsvg%3E"

  @doc """
  Stores every avatar version for `{upload, user}` and returns
  `{:ok, original_file_name}` (kept verbatim in the `:avatar` column), or
  `{:error, :invalid_file}` when the extension is not whitelisted **or the file
  cannot be decoded as an image** (corrupt/truncated uploads used to crash the
  request with a `MatchError`).
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
    Enum.reduce_while(Spec.versions(:avatar), :ok, fn spec, :ok ->
      dest = Path.join(dir, version_filename(scope, spec.name, Spec.served_ext()))

      case Spec.write_derived(spec, rotated, dest) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Re-derives the served versions from the original per the current
  `Vutuv.Uploads.Spec` — see `Vutuv.Uploads.regenerate_from_original/3`,
  which this configures with the avatar layout. Used by
  `Vutuv.Uploads.Regenerator`.
  """
  def regenerate(user, opts \\ []) do
    dir = disk_dir(user)

    Vutuv.Uploads.regenerate_from_original(storage_dir(user), dir,
      canonical: canonical_filenames(user),
      # Everything version-shaped a past pipeline may have left: old-extension
      # versions, publicly stored originals, files named for a previous user
      # name, and the Waffle-era `_large` (512px) the current code never
      # serves.
      stale_glob: "*_*.*",
      legacy_candidates: [Path.join(dir, "*_original.*")],
      derive: &write_derived_versions(&1, user, dir),
      opts: opts
    )
  end

  defp canonical_filenames(scope) do
    for spec <- Spec.versions(:avatar),
        do: version_filename(scope, spec.name, Spec.served_ext())
  end

  @doc """
  Root-relative, URI-encoded URL for a given `{avatar, user}` and served
  version. Returns `nil` when the user has no avatar or for `:original`
  (the original is never URL-addressable).
  """
  def url(file_and_scope, version \\ :medium)
  def url({nil, _scope}, _version), do: nil
  def url({_avatar, _scope}, :original), do: nil

  def url({avatar, scope}, version) do
    local_path = Path.join(storage_dir(scope), served_filename(scope, version, avatar))

    "/"
    |> Path.join(local_path)
    |> URI.encode()
  end

  def user_url(user, version) do
    Vutuv.Avatar.url({user.avatar, user}, version)
  end

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

    with path when not is_nil(path) <- Originals.path(storage_dir(user)),
         {:ok, rotated} <- Spec.open_rotated(path),
         {:ok, small} <- Image.thumbnail(rotated, "#{width}x#{height}", crop: gravity),
         {:ok, data} <- Image.write(small, :memory, suffix: ".jpg") do
      "data:image/jpeg;base64,#{Base.encode64(data)}"
    else
      _ -> @default_avatar
    end
  end

  # The .avif is authoritative; until the regeneration has run, a pre-AVIF
  # derived file with the stored filename's extension keeps resolving.
  # Transitional — remove together with `Spec.legacy_exts/0`.
  defp served_filename(scope, version, avatar) do
    avif = version_filename(scope, version, Spec.served_ext())

    if File.exists?(Path.join(disk_dir(scope), avif)) do
      avif
    else
      legacy_filename(scope, version, avatar) || avif
    end
  end

  defp legacy_filename(scope, version, avatar) do
    candidate = version_filename(scope, version, extname(avatar))
    if File.exists?(Path.join(disk_dir(scope), candidate)), do: candidate
  end

  defp storage_dir(scope), do: "avatars/#{scope.id}"

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
