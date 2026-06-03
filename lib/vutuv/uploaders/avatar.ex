defmodule Vutuv.Avatar do
  @moduledoc """
  Avatar storage and URL generation.

  Replaces the former Waffle uploader with explicit local-disk storage and
  libvips (`Image`) for resizing. The layout matches what production already
  serves (nginx `location /avatars/` aliases the storage directory), so
  existing avatars keep resolving:

      <uploads_dir_prefix>/avatars/<user.id>/<First Last>_<version><ext>

  `uploads_dir_prefix` is the absolute storage root, configured per environment
  (`config :vutuv, :uploads_dir_prefix`); it is empty in dev/test and
  `/srv/legacy-vutuv` in production. URLs are always root-relative
  (`/avatars/<id>/...`) and URI-encoded.
  """

  @versions [:original, :thumb, :medium, :large]
  @extension_whitelist ~w(.jpg .jpeg .png)
  @dimensions %{thumb: 50, medium: 130, large: 512}
  @default_avatar ~s"data:image/svg+xml,%3Csvg%20width%3D%27200%27%20height%3D%27200%27%20xmlns%3D%27http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%27%20xmlns%3Axlink%3D%27http%3A%2F%2Fwww.w3.org%2F1999%2Fxlink%27%3E%3Cdefs%3E%3Ccircle%20id%3D%27a%27%20cx%3D%27100%27%20cy%3D%27100%27%20r%3D%27100%27%2F%3E%3C%2Fdefs%3E%3Cg%20fill%3D%27none%27%20fill-rule%3D%27evenodd%27%3E%3Cmask%20id%3D%27b%27%20fill%3D%27%23fff%27%3E%3Cuse%20xlink%3Ahref%3D%27%23a%27%2F%3E%3C%2Fmask%3E%3Cuse%20fill%3D%27%23EEE%27%20xlink%3Ahref%3D%27%23a%27%2F%3E%3Cpath%20d%3D%27M88.96%20154c-6.357-12.418-12.81-26.952-19.355-43.597C63.06%2093.76%2056.858%2075.626%2051%2056h29.437c1.247%204.844%202.714%2010.093%204.4%2015.743%201.682%205.653%203.428%2011.365%205.24%2017.143%201.808%205.772%203.615%2011.394%205.425%2016.86%201.81%205.466%203.59%2010.434%205.336%2014.904%201.618-4.47%203.365-9.438%205.234-14.905%201.87-5.465%203.71-11.087%205.518-16.86%201.807-5.777%203.554-11.49%205.237-17.142%201.682-5.65%203.15-10.9%204.395-15.743h28.71c-5.857%2019.626-12.055%2037.76-18.594%2054.403C124.8%20127.048%20118.352%20141.583%20112%20154H88.96z%27%20fill%3D%27%231A1918%27%20opacity%3D%27.1%27%20mask%3D%27url(%23b)%27%2F%3E%3C%2Fg%3E%3C%2Fsvg%3E"

  # Resized versions first: they decode the image, so a corrupt or truncated
  # file fails before anything is written; the original is only copied after a
  # successful decode.
  @store_order [:thumb, :medium, :large, :original]

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

  defp write_versions(upload, scope, ext, dir) do
    Enum.reduce_while(@store_order, :ok, fn version, :ok ->
      case write_version(version, upload, scope, ext, dir) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Root-relative, URI-encoded URL for a given `{avatar, user}` and version.
  Returns `nil` when the user has no avatar.
  """
  def url(file_and_scope, version \\ :original)
  def url({nil, _scope}, _version), do: nil

  def url({avatar, scope}, version) do
    local_path = Path.join(storage_dir(scope), version_filename(scope, version, extname(avatar)))

    "/"
    |> Path.join(local_path)
    |> URI.encode()
  end

  @doc "URLs for every version as a `%{version => url}` map."
  def urls(file_and_scope) do
    Map.new(@versions, &{&1, url(file_and_scope, &1)})
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
  The avatar version as a base64 `data:` URI (used by the vCard export), or the
  default inline SVG when the user has no avatar / the file is missing.
  """
  def binary(user, version) do
    user
    |> disk_path(version)
    |> validate_file()
    |> read_file()
  end

  defp disk_path(%{avatar: nil}, _version), do: nil

  defp disk_path(user, version) do
    Path.join(disk_dir(user), version_filename(user, version, extname(user.avatar)))
  end

  defp validate_file(nil), do: nil

  defp validate_file(path) do
    if File.exists?(path), do: path, else: nil
  end

  defp read_file(nil), do: @default_avatar

  defp read_file(path) do
    data = path |> File.read!() |> Base.encode64()
    "data:#{mime_type(path)};base64,#{data}"
  end

  defp mime_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ext when ext in [".jpg", ".jpeg"] -> "image/jpeg"
      ".png" -> "image/png"
      "" -> "application/octet-stream"
      ext -> "image/" <> String.trim_leading(ext, ".")
    end
  end

  defp write_version(:original, upload, scope, ext, dir) do
    File.cp!(upload.path, Path.join(dir, version_filename(scope, :original, ext)))
    :ok
  end

  defp write_version(version, upload, scope, ext, dir) do
    size = Map.fetch!(@dimensions, version)

    with {:ok, image} <- Image.thumbnail(upload.path, "#{size}x#{size}", crop: :center),
         {:ok, _} <- Image.write(image, Path.join(dir, version_filename(scope, version, ext))) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
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
