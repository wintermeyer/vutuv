defmodule Vutuv.AttachmentStore do
  @moduledoc """
  On-disk storage for the files a post or a message carries (issue #2104).

  Like post images and clips there is **no public tree**: every served byte
  will go through an authorizing proxy (#2108), so nothing here gets a
  `Plug.Static` mount or an nginx alias. Two copies per file, keyed by the
  attachment's URL token:

      <uploads_dir_prefix>/attachments/<token>/file.<ext>            the served copy
      <uploads_dir_prefix>/originals/attachments/<token>/original.<ext>   the upload, verbatim

  They are byte-identical today. They are still two files, because the served
  copy is the one #2107 rewrites when an author asks for the metadata to be
  removed, and the promise the private tree makes — that what the member sent
  is kept exactly as they sent it — has to survive that.

  The served copy is written beside its target and renamed, so a process
  killed mid-copy leaves no half file a proxy could hand out.
  """

  alias Vutuv.Uploads
  alias Vutuv.Uploads.Originals

  @served_name "file"
  @root "attachments"

  @doc """
  Keeps `path` under `token`: the verbatim original in the private tree and
  the served copy in `attachments/`. `ext` is the downcased extension the
  **sniffed** format decides, never the one the client's file name claims.
  """
  def store(token, path, ext) when is_binary(ext) do
    :ok = Originals.store(storage_dir(token), path, ext)
    write_served(token, path, ext)
    :ok
  rescue
    exception ->
      # Half a stored file is worse than none: an original with no served copy
      # and no row is invisible to the sweep, which only ever sees rows.
      delete(token)
      reraise(exception, __STACKTRACE__)
  end

  defp write_served(token, path, ext) do
    dir = dir(token)
    File.mkdir_p!(dir)
    dest = Path.join(dir, @served_name <> ext)
    temp = "#{dest}.#{System.unique_integer([:positive])}"
    File.cp!(path, temp)
    File.rename!(temp, dest)
  end

  @doc "The kept upload, or `nil` when it is gone."
  def original_path(token), do: Originals.path(storage_dir(token))

  @doc "The served copy, or `nil` when it is gone."
  def served_path(token) do
    token |> dir() |> Path.join(@served_name <> ".*") |> Path.wildcard() |> List.first()
  end

  @doc "Removes both copies of `token`. A no-op when nothing is stored."
  def delete(token) when is_binary(token) do
    File.rm_rf(dir(token))
    Originals.delete(storage_dir(token))
    :ok
  end

  defp storage_dir(token) do
    # The token is Base64-URL by construction, but never trust a stored value
    # enough to build paths with separators in it.
    false = String.contains?(token, ["/", ".."])
    Path.join(@root, token)
  end

  defp dir(token), do: Uploads.disk_dir(storage_dir(token))
end
