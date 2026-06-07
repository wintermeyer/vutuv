defmodule Vutuv.Cover do
  @moduledoc """
  Profile cover-photo storage and URL generation.

  The wide banner behind the avatar at the top of the profile page. Mirrors
  `Vutuv.Avatar` (explicit local-disk storage + libvips via `Image`), but stores
  a single wide version instead of square crops, because the banner is displayed
  full-bleed with CSS `object-cover`:

      <uploads_dir_prefix>/covers/<user.id>/<First Last>_<version><ext>

  `uploads_dir_prefix` is the absolute storage root, configured per environment
  (`config :vutuv, :uploads_dir_prefix`); it is empty in dev/test and
  `/srv/legacy-vutuv` in production. URLs are always root-relative
  (`/covers/<id>/...`) and URI-encoded. In production nginx serves them with a
  `location /covers/` alias (mirroring `/avatars/`); locally the endpoint serves
  them when `:serve_uploads_locally` is set.
  """

  @extension_whitelist ~w(.jpg .jpeg .png)
  # The banner is shown at most ~768px wide (the profile's main column) but on a
  # HiDPI screen, so we cap the long edge at 1600px. Aspect ratio is preserved;
  # the display crop is done in CSS (object-cover), so important parts of a tall
  # photo are never baked away here.
  @wide_width 1600

  # The resized version first: it decodes the image, so a corrupt or truncated
  # file fails before anything is written; the original is only copied after a
  # successful decode.
  @store_order [:wide, :original]

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

  defp write_versions(upload, scope, ext, dir) do
    Enum.reduce_while(@store_order, :ok, fn version, :ok ->
      case write_version(version, upload, scope, ext, dir) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Root-relative, URI-encoded URL for a given `{cover_photo, user}` and version.
  Returns `nil` when the user has no cover photo.
  """
  def url(file_and_scope, version \\ :wide)
  def url({nil, _scope}, _version), do: nil

  def url({cover, scope}, version) do
    local_path = Path.join(storage_dir(scope), version_filename(scope, version, extname(cover)))

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

  defp write_version(:original, upload, scope, ext, dir) do
    File.cp!(upload.path, Path.join(dir, version_filename(scope, :original, ext)))
    :ok
  end

  defp write_version(:wide, upload, scope, ext, dir) do
    # resize: :down so a smaller upload is stored at its native size rather than
    # blurrily upscaled to @wide_width.
    with {:ok, image} <- Image.thumbnail(upload.path, "#{@wide_width}", resize: :down),
         {:ok, _} <- Image.write(image, Path.join(dir, version_filename(scope, :wide, ext))) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
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
