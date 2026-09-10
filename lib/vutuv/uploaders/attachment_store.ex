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

  A file's rendered preview pages (issue #2105) hang under the served copy's
  own directory, one per page:

      <uploads_dir_prefix>/attachments/<token>/pages/<n>/thumb.avif /lite.avif
                                                        /large.avif
                                                        /pixelated.avif

  So they need no upload tree of their own — nothing new in `.gitignore` and
  nothing new in `test/vutuv/uploads_gitignore_test.exs` — and `delete/1`
  already takes them with the file.
  """

  alias Vutuv.Moderation.Pixelation
  alias Vutuv.Uploads
  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @served_name "file"
  @root "attachments"
  @pages "pages"

  # The served sizes of one preview page, read off `Vutuv.Uploads.Spec` at
  # compile time rather than written out again — the mistake `Vutuv.PressKitStore`
  # records, where a hand-kept second list left the organization store deriving
  # a version no URL of its own could serve.
  @page_versions Enum.map(Spec.versions(:attachment_page), &to_string(&1.name))

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

  ## The preview pages (issue #2105)

  @doc """
  Derives every served size of one already-rendered page and keeps them under
  the file's own token:

      <uploads_dir_prefix>/attachments/<token>/pages/<position>/thumb.avif
                                                              /lite.avif
                                                              /large.avif
                                                              /pixelated.avif

  `source` is the raster the renderer just produced (poppler's PNG of a PDF
  page, or Chromium's capture of a text file). It is a temporary file the
  caller removes: unlike a member's upload there is nothing verbatim to keep,
  because the file it was rendered *from* is already in the private tree and
  re-rendering the page is what `Vutuv.Attachments.Pages.regenerate/2` does.

  Answers `{:ok, %{width:, height:, content_type:, size_bytes:}}`, or
  `{:error, reason}` with the half-written directory removed — a page that
  exists in some sizes and not others is worse than no page.
  """
  def store_page(token, position, source) when is_integer(position) and position >= 0 do
    dir = page_dir(token, position)
    File.mkdir_p!(dir)

    case derive_page(source, dir) do
      {:ok, meta} ->
        {:ok, meta}

      {:error, reason} ->
        File.rm_rf(dir)
        {:error, reason}
    end
  end

  defp derive_page(source, dir) do
    with {:ok, rotated} <- Spec.open_rotated(source),
         :ok <- Spec.write_all(:attachment_page, rotated, &version_dest(dir, &1)) do
      # The stand-in a reader meets while the model looks at this page
      # (issue #1720). Outside the derive loop on purpose, as in every other
      # store: a mosaic is not a version of the picture, it is the temporary
      # absence of one.
      Pixelation.write_if_enabled(rotated, dir)

      {:ok,
       %{
         width: Image.width(rotated),
         height: Image.height(rotated),
         content_type: "image/avif",
         # The largest served size, which is what a reader actually fetches;
         # there is no upload behind a page to report the size of instead.
         size_bytes: File.stat!(version_dest(dir, %{name: :large})).size
       }}
    end
  end

  defp version_dest(dir, %{name: name}), do: Path.join(dir, "#{name}#{Spec.served_ext()}")

  @doc """
  The served sizes a page has, as the strings a URL names them by — what the
  proxy parses a request against, so the whitelist it enforces and the files
  this store writes cannot drift apart.
  """
  def page_versions, do: @page_versions

  @doc "One served size of one page, or `nil` when it is not there."
  def page_version_path(token, position, version)
      when is_binary(token) and is_integer(position) and version in @page_versions do
    exists(Path.join(page_dir(token, position), version <> Spec.served_ext()))
  end

  def page_version_path(_token, _position, _version), do: nil

  @doc "Removes every stored size of one page. A no-op when there is none."
  def delete_page(token, position) when is_binary(token) and is_integer(position) do
    File.rm_rf(page_dir(token, position))
    :ok
  end

  @doc "The directory one page's sizes live in."
  def page_dir(token, position) when is_integer(position) and position >= 0,
    do: token |> page_storage_dir(position) |> Uploads.disk_dir()

  @doc """
  The same directory relative to `uploads_dir_prefix/0`, which is the form the
  shared hold takes (`Vutuv.Uploads.hold/2`). A page is held like a press
  picture: its own `images` row's id names the hold, and the store owns the name
  of the tree the files come out of. The layout is written **here** and read by
  `page_dir/2` above, so the two cannot drift.
  """
  def page_storage_dir(token, position) when is_integer(position) and position >= 0 do
    token |> storage_dir() |> Path.join(@pages) |> Path.join(Integer.to_string(position))
  end

  ## The copyright freeze (issue #2109)

  @doc """
  Moves the file itself — the served copy and the private original — into its
  takedown hold. The preview pages are **not** taken along: each is an `images`
  row with a hold of its own (`Vutuv.Attachments.Pages.hold_files/1`), which is
  what makes `Vutuv.Images.reconcile_holds/0` able to finish an interrupted move
  for them.
  """
  def hold(attachment_id, token) when is_binary(attachment_id) and is_binary(token),
    do: Uploads.hold_at(hold_dir(attachment_id), storage_dir(token))

  @doc "The other direction: the file back in the trees it came out of."
  def release(attachment_id, token) when is_binary(attachment_id) and is_binary(token),
    do: Uploads.release_at(hold_dir(attachment_id), storage_dir(token))

  @doc "Deletes the hold and everything in it. A no-op when there is none."
  def purge_hold(attachment_id) when is_binary(attachment_id),
    do: Uploads.purge_hold_at(hold_dir(attachment_id))

  @doc """
  Where a held file's bytes are, or `nil`. The one thing an admin ruling on a
  copyright claim can read them through, since a freeze takes them out of every
  tree the app serves from.
  """
  def held_path(attachment_id) when is_binary(attachment_id),
    do: Uploads.held_file_at(hold_dir(attachment_id), @served_name <> ".*")

  @doc "Every attachment id with a hold on disk — what the reconcile pass reads."
  def held_ids, do: Uploads.held_ids(@root)

  @doc """
  This file's hold, under a **scope segment** rather than at the root of
  `frozen/` — see `Vutuv.Uploads.nested_hold_dir/2` for why that placement is
  load-bearing rather than tidy.
  """
  def hold_dir(attachment_id) when is_binary(attachment_id),
    do: Uploads.nested_hold_dir(@root, attachment_id)

  defp exists(path), do: if(File.exists?(path), do: path)

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
