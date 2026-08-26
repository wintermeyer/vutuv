defmodule Vutuv.Screenshot do
  @moduledoc """
  URL-screenshot storage and URL generation.

  Explicit local-disk storage with libvips; the served thumb's resolution,
  format and quality come from `Vutuv.Uploads.Spec` (800x528 AVIF — 2x its
  400x264 on-page display size, so it stays crisp on HiDPI screens):

      <uploads_dir_prefix>/screenshots/<url.id>/thumb-<hash>.avif
      <uploads_dir_prefix>/originals/screenshots/<url.id>/original<ext>

  Thumb filenames are **content-fingerprinted**: `<hash>` is the first 12 hex
  chars of the SHA-256 of the captured image. Because the URL changes whenever
  the image bytes change, the files can be cached forever and browsers never
  serve a stale screenshot (no `?v=` query needed). The `screenshot` field
  stores `<hash><ext>` so both the thumb name and the original's extension can
  be rebuilt.

  The captured original keeps its format in the private `originals/` tree
  (`Vutuv.Uploads.Originals`) and is never served. URLs are root-relative
  (`/screenshots/<id>/...`, nginx `location /screenshots/`); pre-AVIF `.webp`
  thumbs keep resolving through a transitional fallback in `url/2` until the
  one-shot regeneration has converted them.
  """

  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Moderation.Pixelation
  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @extension_whitelist ~w(.jpg .png .webp)

  @doc """
  Stores the screenshot versions for `{upload, url}` and returns
  `{:ok, "<hash><ext>"}` (to persist in the `screenshot` field), or
  `{:error, :invalid_file}`.
  """
  def store({%Plug.Upload{} = upload, scope}) do
    if Vutuv.Uploads.valid_extension?(upload.filename, @extension_whitelist) do
      dir = disk_dir(scope)
      hash = Vutuv.Uploads.content_hash(upload.path)
      ext = Path.extname(upload.filename)
      # With AI image moderation on, a fresh capture waits in the quarantine
      # tree (nginx has no location for it) until the scan releases it — a
      # screenshot of an NSFW page must not bypass the upload gate.
      target_dir =
        if ImageScans.enabled?(),
          do: Vutuv.Uploads.quarantine_dir(storage_dir(scope)),
          else: dir

      File.mkdir_p!(target_dir)

      with {:ok, rotated} <- Spec.open_rotated(upload.path),
           # Remove any prior versions first so a regeneration leaves exactly
           # one fingerprinted thumb behind instead of accumulating files.
           :ok <- clear_versions(target_dir),
           :ok <- write_thumb(rotated, target_dir, hash),
           :ok <- clear_displaced_versions(target_dir, dir) do
        Pixelation.write_if_enabled(rotated, dir, hash)
        :ok = Originals.store(storage_dir(scope), upload.path, ext)
        {:ok, "#{hash}#{ext}"}
      else
        _ -> {:error, :invalid_file}
      end
    else
      {:error, :invalid_file}
    end
  end

  # Quarantine-first captures clear the old public thumb only after the new
  # derive succeeded; the classic in-place store already cleared its target.
  defp clear_displaced_versions(dir, dir), do: :ok
  defp clear_displaced_versions(_target_dir, dir), do: clear_versions(dir)

  @doc """
  Releases an approved screenshot from the quarantine tree into the served
  dir (idempotent). Called by the moderation verdict
  (`Vutuv.Moderation.ImageSubjects`); the thumb filename carries only the
  content hash, so no re-derive is ever needed here.
  """
  def promote_from_quarantine(scope) do
    qdir = Vutuv.Uploads.quarantine_dir(storage_dir(scope))

    case Path.wildcard(Path.join(qdir, "*")) do
      [] ->
        :ok

      files ->
        dir = disk_dir(scope)
        File.mkdir_p!(dir)
        clear_versions(dir)
        Pixelation.clear(dir)
        for file <- files, do: File.rename!(file, Path.join(dir, Path.basename(file)))
    end

    File.rm_rf(qdir)
    :ok
  end

  @doc """
  Re-derives the served thumb from the original per the current
  `Vutuv.Uploads.Spec` — see `Vutuv.Uploads.regenerate_from_original/3`,
  which this configures with the screenshot layout. Used by
  `Vutuv.Uploads.Regenerator`.
  """
  def regenerate(url, opts \\ []) do
    if held_in_limbo?(url) do
      # Never materialize an unreleased screenshot into the served tree; its
      # thumb waits in quarantine until the moderation verdict.
      :unchanged
    else
      dir = disk_dir(url)
      hash = rootname(url.screenshot)

      Vutuv.Uploads.regenerate_from_original(storage_dir(url), dir,
        canonical: [thumb_filename(hash, Spec.served_ext())],
        stale_glob: "{thumb,original}*",
        legacy_candidates: [Path.join(dir, "original-*")],
        derive: &write_thumb(&1, dir, hash),
        opts: opts
      )
    end
  end

  # The two screenshot scopes carry their moderation state under different
  # names (urls.screenshot_moderation / post_screenshots.moderation).
  defp held_in_limbo?(scope) do
    Map.get(scope, :screenshot_moderation) == "pending" or
      Map.get(scope, :moderation) == "pending"
  end

  @doc """
  The bundled stand-in shown wherever a screenshot cannot be served: none was
  taken, one is still in moderation limbo, or the row names a file that is not
  on disk.
  """
  def placeholder_url, do: "/images/screenshot.png"

  @doc """
  Root-relative URL for the served thumb, `nil` for `:original` (the original
  is never URL-addressable). Falls back to `placeholder_url/0` when there is no
  screenshot.

  **It also falls back when the row names a file that is not there** (issue
  #1443). A row can outlive its bytes — a release flipped the moderation state
  and then died before promoting the file out of quarantine, and the state is
  invisible to the drift repair, which only looks for rows still `pending`.
  Building the path anyway put a URL that 404s on a public profile for ten
  hours. The `File.exists?` check below already had to run to choose between
  the AVIF and a legacy WebP, so answering "neither" costs nothing and makes
  every such cause degrade to "no screenshot yet" instead of a broken image.
  """
  def url(file_and_scope, version \\ :thumb)

  def url({nil, _scope}, :thumb), do: placeholder_url()
  def url({_screenshot, _scope}, :original), do: nil

  def url({screenshot, scope}, :thumb) do
    cond do
      # Moderation limbo: renders exactly like "no screenshot yet".
      held_in_limbo?(scope) ->
        placeholder_url()

      filename = served_filename(scope, screenshot) ->
        served_url(scope, filename)

      true ->
        placeholder_url()
    end
  end

  @doc """
  Every subject id whose quarantine directory still holds files. The entry
  point of the stranded-quarantine repair (issue #1443, see
  `Vutuv.Moderation.ImageSubjects.settle_stranded_quarantine/0`): reading the
  tree finds the stuck state directly, where a DB query would have to test
  every screenshot row on disk to infer it.
  """
  def quarantined_ids do
    Vutuv.Uploads.quarantine_dir("screenshots")
    |> Path.join("*/*")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
    |> Enum.uniq()
  end

  @doc """
  The content hash of the thumb waiting in `id`'s quarantine directory, or
  `nil`. Compared against the subject's own `screenshot` before anything is
  promoted, so bytes a row has moved on from are never published.
  """
  def quarantined_hash(id) do
    id
    |> quarantine_dir_for()
    |> Path.join("thumb-*")
    |> Path.wildcard()
    |> List.first()
    |> case do
      nil -> nil
      file -> file |> Path.basename() |> Path.rootname() |> String.replace_prefix("thumb-", "")
    end
  end

  @doc "Removes `id`'s quarantine directory, bytes no row claims any more."
  def drop_quarantine(id) do
    File.rm_rf(quarantine_dir_for(id))
    :ok
  end

  defp quarantine_dir_for(id), do: Vutuv.Uploads.quarantine_dir("screenshots/#{id}")

  @doc """
  Removes the screenshot files for `url` — the served thumb and the private
  original. A no-op when none. Called when a URL or its owner's account is
  deleted (the DB cascade drops the `urls` row but never its files).
  """
  def delete(url) do
    File.rm_rf(disk_dir(url))
    File.rm_rf(Vutuv.Uploads.quarantine_dir(storage_dir(url)))
    Originals.delete(storage_dir(url))
    :ok
  end

  # Also sweeps pre-AVIF leftovers: legacy `.webp` thumbs and the originals
  # that used to live in this public directory.
  defp clear_versions(dir) do
    for file <- Path.wildcard(Path.join(dir, "{thumb,original}*")), do: File.rm(file)
    :ok
  end

  ## The pixelated preview (issue #1720)

  # A capture waiting for the AI verdict has nothing in the served directory —
  # its thumb is in quarantine, which nginx cannot reach — so the page showed
  # the generic placeholder and a reader could not tell a page being checked
  # from one that failed to capture. The preview goes into the **served**
  # directory instead: it is the one thing about this capture that may be
  # published before the verdict, being 64 cells of averaged colour rather than
  # the page.
  #
  # `Pixelation.write_if_enabled/3` decides whether there is a wait to stand in
  # for at all, and it is the same question the quarantine choice in `store/1`
  # asks — so the two cannot answer it differently.

  @doc """
  Root-relative URL of the preview standing in for a capture the AI scan has
  not released, or `nil` when there is nothing to stand in with: the capture is
  released (the thumb itself is served), the wait has run past
  `Vutuv.Moderation.Pixelation.window_seconds/0`, or no preview was written.

  Both screenshot scopes carry an `updated_at`, and that is when the wait
  started: the row is touched by the capture that is now being judged.
  """
  def pixelated_url(scope) do
    with true <- held_in_limbo?(scope),
         hash when hash != "" <- rootname(scope.screenshot),
         filename = Pixelation.filename(hash),
         true <- Pixelation.stands_in?(Path.join(disk_dir(scope), filename), scope.updated_at) do
      served_url(scope, filename)
    else
      _ -> nil
    end
  end

  defp write_thumb(rotated, dir, hash) do
    spec = Spec.version(:screenshot, :thumb)
    Spec.write_derived(spec, rotated, Path.join(dir, thumb_filename(hash, Spec.served_ext())))
  end

  # The .avif is authoritative; until the regeneration has run, a pre-AVIF
  # `.webp` thumb keeps resolving. Transitional — remove together with
  # `Spec.legacy_exts/0`. `nil` when neither is on disk, which is what makes
  # `url/2` fail closed (issue #1443) instead of naming a file that 404s.
  defp served_filename(scope, screenshot) do
    avif = thumb_filename(rootname(screenshot), Spec.served_ext())

    cond do
      File.exists?(Path.join(disk_dir(scope), avif)) -> avif
      (legacy = legacy_filename(scope, screenshot)) != nil -> legacy
      true -> nil
    end
  end

  defp legacy_filename(scope, screenshot) do
    candidate = thumb_filename(rootname(screenshot), ".webp")
    if File.exists?(Path.join(disk_dir(scope), candidate)), do: candidate
  end

  defp thumb_filename(hash, ext), do: "thumb-#{hash}#{ext}"

  # The one place a served screenshot file becomes a URL.
  defp served_url(scope, filename),
    do: "/" |> Path.join(Path.join(storage_dir(scope), filename)) |> URI.encode()

  defp storage_dir(scope), do: "screenshots/#{scope.id}"

  defp disk_dir(scope), do: Vutuv.Uploads.disk_dir(storage_dir(scope))

  defp rootname(nil), do: ""

  defp rootname(value) when is_binary(value),
    do: value |> Vutuv.Uploads.strip_query() |> Path.rootname()
end
