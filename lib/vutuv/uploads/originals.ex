defmodule Vutuv.Uploads.Originals do
  @moduledoc """
  The one private home of every uploaded original, shared by all uploaders
  (avatars, covers, screenshots, post images):

      <uploads_dir_prefix>/originals/<storage_dir>/original<ext>

  Originals are kept verbatim — format and metadata included; the point of
  keeping them is re-deriving better formats later (`Vutuv.Uploads.Spec` +
  `Vutuv.Uploads.Regenerator`). The `originals/` tree is **never served**:
  it has no `Plug.Static` mount and must never get an nginx alias, so nobody
  can download a full-resolution upload (with its EXIF/GPS data).

  The on-disk name is always `original<ext>` — never the client-supplied
  filename (that is column metadata, not a path) — and there is exactly one
  original per storage dir: a re-upload clears the stale one first, whatever
  its extension.
  """

  @doc """
  Copies the uploaded file at `source_path` to the private original location
  for `storage_dir` (e.g. `"avatars/7"`), replacing any prior original.
  """
  def store(storage_dir, source_path, ext) do
    dir = dir(storage_dir)
    File.mkdir_p!(dir)
    clear(dir)
    File.cp!(source_path, Path.join(dir, "original#{ext}"))
    :ok
  end

  @doc """
  The absolute path of the stored original for `storage_dir`, whatever its
  extension, or `nil` when there is none.
  """
  def path(storage_dir) do
    storage_dir
    |> dir()
    |> Path.join("original*")
    |> Path.wildcard()
    |> List.first()
  end

  @doc """
  Finds the original for `storage_dir`: the private one when present,
  otherwise the first match of the legacy `candidates` globs (the public
  locations originals lived in before the private tree existed). Returns
  `{:private, path}`, `{:legacy, path}` or `nil`.
  """
  def locate(storage_dir, candidates) do
    if path = path(storage_dir) do
      {:private, path}
    else
      case candidates |> Enum.flat_map(&Path.wildcard/1) |> List.first() do
        nil -> nil
        legacy -> {:legacy, legacy}
      end
    end
  end

  @doc """
  Like `locate/2`, but **moves** a legacy original into the private tree
  first. Returns the private path, or `nil` when no original exists anywhere.
  """
  def adopt(storage_dir, candidates) do
    case locate(storage_dir, candidates) do
      {:private, path} ->
        path

      {:legacy, legacy} ->
        :ok = store(storage_dir, legacy, Path.extname(legacy))
        File.rm(legacy)
        path(storage_dir)

      nil ->
        nil
    end
  end

  @doc "Removes the original of `storage_dir`. A no-op when nothing is stored."
  def delete(storage_dir) do
    File.rm_rf(dir(storage_dir))
    :ok
  end

  @doc "The absolute private directory for `storage_dir`."
  def dir(storage_dir) when is_binary(storage_dir) do
    Vutuv.Uploads.disk_dir(Path.join("originals", storage_dir))
  end

  defp clear(dir) do
    for file <- Path.wildcard(Path.join(dir, "original*")), do: File.rm(file)
    :ok
  end
end
