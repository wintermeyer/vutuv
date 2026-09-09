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

  Two files may sit **beside** an original rather than under the served
  versions: a copy derived from it that must not become reachable by URL
  construction. `cleaned_copy/3` below writes the first of them; the other is a
  store's own (`Vutuv.PostImageStore`'s cropped download and crop workbench).
  """

  alias Vutuv.Uploads.MetadataStrip

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

  @doc """
  The **cleaned copy** of a kept original, as `{path, ext}`: the same pixels
  with every metadata block removed (`Vutuv.Uploads.MetadataStrip`), derived
  once on first request and cached beside the original as `cleaned<ext>`.

  **It fails closed.** A container the stripper cannot take apart yields `nil`
  rather than the untouched file, because the whole point of offering a cleaned
  copy is the promise that the file carries nothing but the picture, and falling
  back to the upload would break exactly that promise while looking like it
  worked.

  Written here rather than in each store because both places that hand a
  full-resolution file over make the same promise — the post photo's
  author-enabled download (#1104) and the press kit's, which is a whole section
  built on it (#2083) — and a fix to either the fail-closed rule or the atomic
  publish must not reach only one of them.
  """
  def cleaned_copy(storage_dir, original, ext) do
    dest = Path.join(dir(storage_dir), "cleaned#{ext}")

    cond do
      File.exists?(dest) -> {dest, ext}
      # A fast path only: `strip/2` sniffs the bytes and answers `:unsupported`
      # for these containers anyway, but reading a 30 MB press photo to find
      # that out is what this skips.
      not MetadataStrip.supported?(ext) -> nil
      true -> write_cleaned(original, dest, ext)
    end
  end

  defp write_cleaned(original, dest, ext) do
    case MetadataStrip.strip(original, ext) do
      :unsupported -> nil
      bytes -> {publish(dest, bytes), ext}
    end
  end

  @doc """
  Writes `bytes` to `dest` in the private tree and returns the path — beside the
  target and renamed, so two concurrent downloads can never serve a half-written
  file. Every derivative cached next to an original goes through this.
  """
  def publish(dest, bytes) do
    File.mkdir_p!(Path.dirname(dest))
    temp = "#{dest}.#{System.unique_integer([:positive])}"
    File.write!(temp, bytes)
    File.rename!(temp, dest)
    dest
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
