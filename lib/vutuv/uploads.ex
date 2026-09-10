defmodule Vutuv.Uploads do
  @moduledoc """
  The toolset shared by all local-disk uploaders (`Vutuv.Avatar`,
  `Vutuv.Cover`, `Vutuv.Screenshot`, `Vutuv.PostImageStore`): storage-root
  resolution and the one regeneration driver every image type goes through
  (`regenerate_from_original/3`). Private originals live in
  `Vutuv.Uploads.Originals`, version specs and the AVIF encoder in
  `Vutuv.Uploads.Spec`.

  Directory orientation for new readers: `lib/vutuv/uploads/` (this context)
  is the shared pipeline; `lib/vutuv/uploaders/` holds the per-asset-type
  modules (avatar, cover, post image, screenshot) that configure it.

  For a profile picture the avatar/cover half of this pipeline takes
  `{image, scope}` — the picture's row in the shared `images` table
  (`Vutuv.Images.member_image/2`, resolved once by the uploader) beside whose
  it is. Since #2027 that row is where the file name, the fingerprint, the crop
  and the moderation verdict are read from; the member row's four columns per
  kind are still written but no longer read, and go a deploy later.
  """

  require Logger

  alias Vutuv.Images
  alias Vutuv.Images.Image
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Repo
  alias Vutuv.Uploads.Crop
  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec
  alias Vutuv.UUIDv7

  # The takedown hold's root, under `uploads_dir_prefix/0` (see `hold_dir/1`).
  @hold_root "frozen"

  # Length (hex chars) of the content fingerprint baked into served filenames.
  # 12 hex = 48 bits — collision-safe within a single id-scoped directory
  # (one image's versions), which is all that shares a dir.
  @hash_length 12

  # Every column an upload's own file name is written into is varchar(255):
  # `users.avatar`, `users.cover_photo` and `images.file`. See
  # `max_stored_file_name/0`.
  @max_stored_file_name 255

  @typedoc """
  Per-uploader layout passed to the shared `store/3`, `url/3` and
  `regenerate/3` pipeline (`Vutuv.Avatar` and `Vutuv.Cover` differ only in
  these knobs):

    * `:spec_key` — the `Vutuv.Uploads.Spec.versions/1` key (`:avatar | :cover`)
    * `:prefix` — the served-tree storage prefix (`"avatars"` / `"covers"`)
    * `:default_version` — the version `url/3` serves when none is given
    * `:kind` — this image's kind in the shared `images` table
      (`Vutuv.Images`). Since #2027 the row of that kind is what every function
      here reads the picture's `file` / `fingerprint` / `crop` / `moderation`
      from; the caller resolves it once (`Vutuv.Images.member_image/2`) and
      hands it in as `{image, scope}`
    * `:fingerprint_field` — the **member-row column** a re-derive writes the
      fresh fingerprint back into (`:avatar_fingerprint` /
      `:cover_fingerprint`). A write, not a read: both copies stay in step
      until the column drop
    * `:moderated` — whether the AI image gate screens this kind, which decides
      the tree a fresh upload's bytes land in
  """
  @type uploader_config :: %{
          required(:spec_key) => atom(),
          required(:prefix) => String.t(),
          required(:default_version) => atom(),
          optional(:fingerprint_field) => atom(),
          optional(:moderated) => boolean(),
          optional(:kind) => String.t()
        }

  @doc """
  The absolute storage root, configured per environment via
  `config :vutuv, :uploads_dir_prefix` (env var `UPLOADS_DIR_PREFIX`). Empty in
  dev/test; every installation sets its own in production, and vutuv.de's is
  `/srv/vutuv3`. `/srv/legacy-vutuv` is only the fallback `runtime.exs` names
  when the env var is absent — this doc used to quote it as if it were the
  production path, which sent an investigation looking for a member's files in
  a directory that does not exist on the server.
  """
  def uploads_dir_prefix, do: Application.get_env(:vutuv, :uploads_dir_prefix, "")

  @doc """
  The absolute on-disk directory for a relative `storage_dir`
  (e.g. `"avatars/7"`), rooted at `uploads_dir_prefix/0`.
  """
  def disk_dir(storage_dir) when is_binary(storage_dir) do
    Path.join(uploads_dir_prefix(), storage_dir)
  end

  @doc """
  The **quarantine** twin of a served directory: while AI image moderation
  holds an nginx-served image in limbo, its derived versions live under
  `quarantine/<storage_dir>` — a tree nginx has no location for, so an
  unreleased byte is unreachable by URL no matter what a display helper
  renders. Approval moves the files into the served dir; rejection removes
  the whole tree.
  """
  def quarantine_dir(storage_dir) when is_binary(storage_dir) do
    disk_dir(Path.join("quarantine", storage_dir))
  end

  @doc """
  The **takedown hold** of one picture: `frozen/<image id>`, with a
  subdirectory per tree the files came out of (`served/`, `original/`,
  `quarantine/`). Like the quarantine tree it is a tree nginx has no location
  for, so a byte in here is unreachable by URL; unlike it, it is keyed by the
  `Vutuv.Images` row rather than by the storage dir, and moving a file into it
  is reversible (`Vutuv.Images.freeze/1`, issue #2012).

  A root of its own rather than a corner of `quarantine/`: both holds move
  *everything* in a directory, so sharing one tree would mean the AI gate's
  release handing a frozen picture back to the world (and a freeze swallowing
  a picture waiting for a verdict).
  """
  def hold_dir(image_id) when is_binary(image_id), do: disk_dir(Path.join(@hold_root, image_id))

  @doc """
  Every hold on disk, by image id — the record `Vutuv.Images.reconcile_holds/0`
  reads to find work a dying slot left half-done. One `readdir` of a tree that
  is empty on almost every installation, plus a `stat` per hold; the hold layout
  is written here and nowhere else.

  A hold is a **directory named by an image id**, and only those come back:
  anything else in that root reaches `where: i.id in ^ids`, which raises rather
  than matching nothing, and takes the whole pass with it (issue #2031).
  """
  def held_image_ids do
    root = disk_dir(@hold_root)

    case File.ls(root) do
      {:ok, entries} -> Enum.filter(entries, &hold?(root, &1))
      {:error, _reason} -> []
    end
  end

  defp hold?(root, entry) do
    UUIDv7.cast_or_nil(entry) != nil and File.dir?(Path.join(root, entry))
  end

  # Which tree each slot of a hold came from, so `release/3` puts every file
  # back where it was rather than flattening three trees into one.
  defp hold_slots(storage_dir) do
    %{
      "served" => disk_dir(storage_dir),
      "original" => Originals.dir(storage_dir),
      "quarantine" => quarantine_dir(storage_dir)
    }
  end

  @doc "The `{scope, config}` twin of `hold/2`, for an uploader keyed that way."
  def hold(image_id, scope, config), do: hold(image_id, storage_dir(scope, config))

  @doc """
  Moves every stored file under `storage_dir` — derived versions, the private
  original and anything still in AI quarantine — into the hold of `image_id`.

  The directory is the primitive, because the loop and `hold_slots/1` never
  wanted anything else: a profile picture's tree is `<prefix>/<member id>` and a
  press picture's is `press_kit/<token>`, with no scope to derive it from.

  **Restartable by construction.** Each file is moved on its own with an atomic
  rename, so an interruption leaves every file whole on one side or the other
  and never a copy on both; running it again moves whatever is left. That is
  what `Vutuv.Images.reconcile_holds/0` does, and it is why the row is stamped
  `frozen_at` *before* this runs: the stamp is the record of the intent, and
  the move is the part that may need a second attempt.
  """
  def hold(image_id, storage_dir) when is_binary(storage_dir) do
    for {slot, source} <- hold_slots(storage_dir),
        do: move_all(source, Path.join(hold_dir(image_id), slot))

    :ok
  end

  @doc "The `{scope, config}` twin of `release/2`, for an uploader keyed that way."
  def release(image_id, scope, config), do: release(image_id, storage_dir(scope, config))

  @doc """
  The other direction: every file in the hold of `image_id` goes back to the
  tree it came from, at the name it had. The (now empty) hold is left standing
  — `Vutuv.Images.unfreeze/1` removes it only once the picture is reachable
  again, so an interruption is still visible as a hold to finish.
  """
  def release(image_id, storage_dir) when is_binary(storage_dir) do
    for {slot, target} <- hold_slots(storage_dir),
        do: move_all(Path.join(hold_dir(image_id), slot), target)

    :ok
  end

  @doc "Deletes the hold of `image_id` and everything in it. A no-op when there is none."
  def purge_hold(image_id) when is_binary(image_id) do
    File.rm_rf(hold_dir(image_id))
    :ok
  end

  @doc """
  The on-disk path of one held derived version, for the authorized preview the
  case pages show (`VutuvWeb.ModerationCaseController.image/2`). `nil` when
  there is none.

  The hold's twin of `version_path/3`, and deliberately not a call to it: a
  member who renames while their picture is held keeps the old handle in the
  file name, and no scope reaches here to rebuild it from, so this matches what
  is on disk instead. Both schemes, because a hold has to answer for whichever
  one the picture was stored under — the fingerprinted name first, then the
  legacy one a row that never reached a fingerprint carries. Missing the second
  drew a broken image on the case page for those pictures, and an admin who
  cannot see a picture cannot rule on the claim about it (issue #2031).
  """
  def held_version_path(image_id, version, fingerprint) when is_binary(image_id) do
    dir = hold_dir(image_id)

    fingerprinted =
      is_binary(fingerprint) && first_match(dir, fingerprinted_glob(version, fingerprint))

    fingerprinted || first_match(dir, legacy_version_glob(version))
  end

  def held_version_path(_image_id, _version, _fingerprint), do: nil

  @doc """
  The on-disk path of one held file by the **name it has**, or `nil`.

  For a kind whose served files are named by version alone inside a directory of
  their own (`press_kit/<token>/large.avif`, issue #2089): neither naming scheme
  `held_version_path/3` globs for is on disk there, so the store that owns the
  name asks for it. Every slot again, for the same reason.
  """
  def held_file_path(image_id, filename) when is_binary(image_id) and is_binary(filename),
    do: first_match(hold_dir(image_id), filename)

  # Every slot, not just `served/`: a picture frozen while the AI gate still had
  # it keeps its versions under `quarantine/`. The private original stays out of
  # reach — it is never shown to anybody, and neither glob matches its
  # `original<ext>` name.
  defp first_match(dir, glob),
    do: dir |> Path.join("*/#{glob}") |> Path.wildcard() |> List.first()

  # One directory's files, moved one atomic rename at a time. Nothing recurses:
  # every tree an uploader writes is flat.
  defp move_all(from, to) do
    case Path.wildcard(Path.join(from, "*")) do
      [] ->
        :ok

      files ->
        File.mkdir_p!(to)
        for file <- files, do: File.rename!(file, Path.join(to, Path.basename(file)))
        :ok
    end
  end

  @doc """
  Drops a legacy `"?<timestamp>"` cache-busting suffix from a stored filename.
  """
  def strip_query(value) when is_binary(value), do: String.replace(value, ~r/\?\d+$/, "")

  @doc """
  Operator stdout progress for the uploads mix tasks (regenerate / sweep /
  relabel), silenced in the test env via `:regenerator_quiet`. The single home
  for this, so the quiet flag can't drift between the three task modules.
  """
  def log(message) do
    unless Application.get_env(:vutuv, :regenerator_quiet, false), do: IO.puts(message)
    :ok
  end

  @doc """
  Stores every derived version for `{upload, scope}` per `config` and returns
  `{:ok, original_file_name, fingerprint, moderation}` — the upload's own name
  (cut to `max_stored_file_name/0`), the content
  fingerprint (`sha256(original)[0..#{@hash_length - 1}]`)
  and the moderation state the bytes were actually stored under, all three for
  the caller's columns — or `{:error, :invalid_file}` when the extension is not
  whitelisted **or the file cannot be decoded as an image** (corrupt/truncated
  uploads used to crash the request with a `MatchError`).

  The moderation state comes back rather than being read a second time by the
  caller: this function is where `:moderate_images` decides which tree the
  bytes land in, so it is also where the state the row records is decided —
  one read, and the two can never disagree. `nil` for an uploader with no
  moderation column.

  The served files are written under the fingerprinted scheme-B name
  `<handle>-<version>-<fingerprint>.avif`, so a fresh upload is immediately on
  the new scheme (its URL carries the fingerprint, no `?v=`).

  Order matters: the derived versions decode the image, so a corrupt or
  truncated file fails before anything on disk is touched; only then are the
  prior versions cleared, the new ones written, and the original copied
  (privately). Clearing prior versions keeps exactly one image set per dir, so a
  re-upload never accumulates stale fingerprinted/legacy files.

  """
  def store({%Plug.Upload{} = upload, scope}, config, crop \\ nil) do
    if valid_extension?(upload.filename) do
      ext = Path.extname(upload.filename)
      storage_dir = storage_dir(scope, config)
      dir = disk_dir(storage_dir)
      # The crop is folded into the fingerprint so re-cropping the *same*
      # original yields a different filename (and a cache-safe URL); see
      # content_hash/2. The crop only shapes the derived (served) versions —
      # the original is kept verbatim and uncropped, so a future re-derive (or
      # re-crop) starts from the full upload.
      fingerprint = content_hash(upload.path, crop)
      # Moderated uploaders write into the quarantine tree; the scan verdict
      # moves the files into the served dir (approve) or removes everything
      # (reject). The old public image is cleared only after the new derive
      # succeeded, so a corrupt upload never costs the current image.
      moderation = initial_moderation(config)
      target_dir = if moderation == "pending", do: quarantine_dir(storage_dir), else: dir
      File.mkdir_p!(target_dir)

      with {:ok, rotated} <- Spec.open_rotated(upload.path),
           {:ok, cropped} <- Crop.apply_to(rotated, Crop.parse(crop)),
           :ok <- clear_public_versions(target_dir),
           :ok <- write_derived_versions(cropped, target_dir, scope, fingerprint, config),
           :ok <- clear_displaced_versions(target_dir, dir),
           :ok <- Originals.store(storage_dir, upload.path, ext) do
        {:ok, stored_file_name(upload.filename), fingerprint, moderation}
      else
        {:error, _reason} -> {:error, :invalid_file}
      end
    else
      {:error, :invalid_file}
    end
  end

  # The upload's own name, cut to what its columns hold, extension kept.
  #
  # A name comes off a phone or a scanner, not out of a form, and nothing
  # resolves a file through it — the served name is
  # `<handle>-<version>-<fingerprint>.avif`, the private original is
  # `original<ext>` — so it is bookkeeping. That is why an over-long one is cut
  # rather than refused: turning a good picture away over its *name* refuses it
  # for something that is not about the picture (issue #2025).
  defp stored_file_name(filename) when is_binary(filename) do
    ext = Path.extname(filename)
    keep = @max_stored_file_name - code_points(ext)

    cond do
      code_points(filename) <= @max_stored_file_name -> filename
      # A name that is nearly all extension leaves no room to keep it.
      keep < 1 -> cut_to_code_points(filename, @max_stored_file_name)
      true -> cut_to_code_points(filename, keep) <> ext
    end
  end

  # Measured and cut in **code points**, because that is what varchar(255)
  # counts, while `String.length/1` counts graphemes — and the two differ on
  # exactly the names this site gets. macOS hands over decomposed (NFD) names,
  # where every `ä` is one grapheme and two code points, so a 200-character
  # German name is 400 code points and still raises Postgres 22001. Cut on a
  # grapheme boundary all the same, so the result never ends in an orphaned
  # combining accent.
  defp cut_to_code_points(string, max) do
    string
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {kept, used} ->
      used = used + code_points(grapheme)
      if used <= max, do: {:cont, {[grapheme | kept], used}}, else: {:halt, {kept, used}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp code_points(string), do: string |> String.to_charlist() |> length()

  @doc """
  How much of an upload's own file name is kept — the width of every column it
  is written into (`users.avatar`, `users.cover_photo`, `images.file`), in
  characters.

  Read by `Vutuv.Images.Image.changeset/2` as well, so the cutter and the
  validation guarding the same write cannot drift apart.
  """
  def max_stored_file_name, do: @max_stored_file_name

  # Quarantine-first uploads clear the old public image only after the new
  # derive succeeded (limbo shows the placeholder, per spec); the classic
  # in-place store already cleared its target above.
  defp clear_displaced_versions(dir, dir), do: :ok
  defp clear_displaced_versions(_target_dir, dir), do: clear_public_versions(dir)

  # The state this uploader's fresh files start in — the **single** read of
  # `:moderate_images` per store. "pending" puts the bytes in the quarantine
  # tree and is what the caller writes onto its row; nil is an uploader with no
  # moderation column, which has neither.
  defp initial_moderation(config) do
    if Map.get(config, :moderated, false), do: ImageScans.initial_state()
  end

  @doc """
  Releases a moderated image: moves the quarantined derived versions into the
  served dir (clearing whatever was there, so exactly one image set remains)
  and, as self-healing, re-derives from the private original when the
  current-handle fingerprinted files still aren't all present afterwards
  (e.g. a username change while the image waited in limbo). Idempotent — an
  empty quarantine with converged served files is a no-op.
  """
  def promote_from_quarantine({image, scope}, config) do
    storage_dir = storage_dir(scope, config)
    qdir = quarantine_dir(storage_dir)
    dir = disk_dir(storage_dir)

    unless Path.wildcard(Path.join(qdir, "*")) == [] do
      File.mkdir_p!(dir)
      clear_public_versions(dir)
      move_all(qdir, dir)
    end

    File.rm_rf(qdir)

    # Converged rows return :unchanged here (cheap file-exists checks).
    case regenerate({image, scope}, [], config) do
      {:error, reason} -> Logger.warning("promote self-heal failed: #{inspect(reason)}")
      _ -> :ok
    end

    :ok
  end

  # The first 12 hex of the SHA-256 of the uploaded bytes **plus the crop
  # string** — the content fingerprint baked into the served filename. Hashing
  # the **original** (not a derived version) makes it deterministic, so a
  # regeneration of the same image and crop produces the same name (idempotent
  # migration) and an identical re-upload reuses the same URL. Folding the crop
  # in means re-cropping the same original yields a fresh fingerprint, so the
  # immutable (`?v=`-less) URL changes and no stale crop is served from cache.
  # A nil crop appends "", leaving the no-crop hash byte-identical to before.
  def content_hash(path, crop \\ nil) do
    :sha256
    |> :crypto.hash(File.read!(path) <> (crop || ""))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_length)
  end

  # Empties the public served dir before writing the new versions, so a
  # re-upload leaves exactly one image set (no stale fingerprinted or legacy
  # files). The private original lives in a separate tree and is untouched here.
  defp clear_public_versions(dir) do
    for file <- Path.wildcard(Path.join(dir, "*")), do: File.rm(file)
    :ok
  end

  @doc """
  The formats a profile picture (avatar, cover) may arrive in: whatever a post
  photo may be, HEIC capability-detection included.

  Deliberately the same list rather than one of its own. A member's picture
  comes off a phone or out of a design tool, and this was the narrowest
  whitelist on the site — JPEG and PNG alone — while a WebP logo or a HEIC
  snapshot passed everywhere else, so refusing it here was a dead end nobody
  could debug. SVG stays out with it: a profile picture is a photograph, and a
  vector one would be the only member-uploaded markup the AI gate has to reason
  about.
  """
  defdelegate extension_whitelist, to: Vutuv.PostImageStore

  @doc "The largest profile picture a member may upload, in bytes."
  def max_filesize, do: Keyword.fetch!(config(), :max_filesize)

  defp config, do: Application.fetch_env!(:vutuv, :profile_images)

  @doc """
  Whether `upload` is a storable image — a whitelisted extension whose bytes
  decode as an image — **without writing anything to disk**. The pre-commit
  half of `store/2`: a changeset validates here, and only after the row
  commits does the caller `store/2` (which writes), so a rolled-back write
  can never orphan files on disk (issue #776).
  """
  def valid_upload?(%Plug.Upload{} = upload) do
    valid_extension?(upload.filename) and match?({:ok, _}, Spec.open_rotated(upload.path))
  end

  def valid_upload?(_), do: false

  @doc """
  Root-relative, URI-encoded URL for a given `{image, scope}` and served
  version per `config` — `image` being the picture's row in the shared
  `images` table (`Vutuv.Images.member_image/2`), or `nil` for a member with no
  picture of that kind.

  `nil` whenever there is nothing a reader may fetch: no picture, a picture the
  AI gate still holds, a picture a copyright case froze, or `:original` (the
  private original is never URL-addressable).
  """
  def url({image, scope}, version, config) do
    cond do
      version == :original -> nil
      not servable?(image) -> nil
      true -> served_url(image, scope, version, config)
    end
  end

  @doc """
  The on-disk path of a served version (the `.avif`, or the transitional
  pre-AVIF file), or `nil` when none exists. Lets the avatar link-preview
  JPEG (`Vutuv.Avatar.og_jpeg/1`) derive from the best available image
  when no private original was kept (legacy uploads predate the kept
  originals).
  """
  def version_path({%Image{} = image, scope}, version, config) do
    dir = disk_dir(storage_dir(scope, config))

    name =
      case image.fingerprint do
        nil -> served_filename(scope, version, image.file, config)
        fp -> fingerprinted_filename(scope, version, fp, config)
      end

    path = Path.join(dir, name)
    if File.exists?(path), do: path
  end

  def version_path({nil, _scope}, _version, _config), do: nil

  @doc """
  The on-disk path of a **quarantined** derived version — the owner's limbo
  preview (`VutuvWeb.PendingImageController`); nobody else ever sees these
  bytes. `nil` when absent.
  """
  def quarantine_version_path({%Image{fingerprint: fp}, scope}, version, config)
      when is_binary(fp) do
    path =
      storage_dir(scope, config)
      |> quarantine_dir()
      |> Path.join(fingerprinted_filename(scope, version, fp, config))

    if File.exists?(path), do: path
  end

  def quarantine_version_path(_image_and_scope, _version, _config), do: nil

  @doc """
  Migrates one avatar/cover row to the fingerprinted scheme (or re-derives a row
  already on it), **keeping any legacy files in place** — the expand half of the
  expand/contract migration. Called per row by `Vutuv.Uploads.Regenerator`.

  Crash-safe order: adopt the original into the private tree, derive the
  `<handle>-<version>-<fp>.avif` files, **then** persist the fingerprint column.
  A crash between the two leaves new files unreferenced (the row's still-nil
  column serves the legacy URL) — never a referenced-but-missing file — and a
  re-run converges. The old legacy files are deliberately NOT swept here, so the
  previous release (and a rollback) keep serving them; `mix
  vutuv.images.sweep_legacy` removes them later, once the scheme is confirmed.

  Returns `:ok` (migrated/re-derived), `:unchanged` (already converged),
  `{:skipped, :missing_original}` (files left untouched) or `{:error, reason}`.
  """
  def regenerate({image, user}, opts, config) do
    storage_dir = storage_dir(user, config)
    dir = disk_dir(storage_dir)
    fingerprint = image && image.fingerprint

    cond do
      # Nothing to re-derive, or nothing that MAY be re-derived: a picture the
      # AI gate still holds lives in the quarantine tree and one a copyright
      # case froze lives in the takedown hold, and writing fresh versions into
      # the served tree would hand either of them back to the world.
      not servable?(image) ->
        :unchanged

      opts[:dry_run] ->
        dry_run_fingerprinted(user, storage_dir, dir, fingerprint, config)

      fingerprint_converged?(user, dir, fingerprint, config) and
          not Keyword.get(opts, :force, false) ->
        :unchanged

      true ->
        migrate_to_fingerprinted(image, user, storage_dir, dir, config)
    end
  end

  @doc """
  Re-derives the fingerprinted files under `user`'s **current** handle after a
  username change, so the username-in-the-filename URL keeps resolving. A no-op for a
  row not yet on the fingerprinted scheme (its legacy URL is name/id-based, not
  username-based). Works off the private original, so it never depends on the
  old-handle files still being present. See `Accounts.update_username/2`.
  """
  def reslug({image, user}, config) do
    if image && image.fingerprint do
      regenerate({image, user}, [force: true], config)
    else
      :unchanged
    end
  end

  @doc """
  Contract half of the migration: removes every file in the served dir that is
  not a current fingerprinted version (the leftover legacy `.jpg`/`.avif` and any
  stale-fingerprint/old-handle files). Deliberately separate from `regenerate/3`
  so the destructive step is never automatic. Safe by construction:

    * a row with no fingerprint (still legacy) is left entirely alone;
    * a row whose current fingerprinted files are not all present is left alone
      (never strip the legacy files out from under a half-migrated row).

  `dry_run: true` reports without deleting. Returns `{:swept, names}`,
  `{:dry_run, names}` or `:unchanged`.
  """
  def sweep_legacy({image, user}, opts, config) do
    fingerprint = image && image.fingerprint
    dir = disk_dir(storage_dir(user, config))

    cond do
      is_nil(fingerprint) -> :unchanged
      # A held picture's files are not in the served tree at all, so there is
      # nothing here to call stale — and nothing to prove the scheme by.
      not servable?(image) -> :unchanged
      not fingerprint_converged?(user, dir, fingerprint, config) -> :unchanged
      true -> remove_stale_files(user, dir, fingerprint, opts, config)
    end
  end

  defp remove_stale_files(user, dir, fingerprint, opts, config) do
    keep = current_fingerprinted_names(user, fingerprint, config)

    stale =
      dir
      |> Path.join("*")
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) in keep))

    if opts[:dry_run] do
      {:dry_run, Enum.map(stale, &Path.basename/1)}
    else
      for file <- stale, do: File.rm(file)
      {:swept, Enum.map(stale, &Path.basename/1)}
    end
  end

  defp current_fingerprinted_names(user, fingerprint, config) do
    for spec <- Spec.versions(config.spec_key),
        do: fingerprinted_filename(user, spec.name, fingerprint, config)
  end

  # All current-handle fingerprinted files present (the column is set): nothing
  # to do. A nil fingerprint is never converged — the row still needs migrating.
  defp fingerprint_converged?(_user, _dir, nil, _config), do: false

  defp fingerprint_converged?(user, dir, fingerprint, config) do
    Enum.all?(Spec.versions(config.spec_key), fn spec ->
      File.exists?(Path.join(dir, fingerprinted_filename(user, spec.name, fingerprint, config)))
    end)
  end

  defp migrate_to_fingerprinted(image, user, storage_dir, dir, config) do
    case Originals.adopt(storage_dir, [Path.join(dir, "*_original.*")]) do
      nil ->
        {:skipped, :missing_original}

      original ->
        File.mkdir_p!(dir)
        # Re-apply the user's persisted crop so a re-derive from the kept
        # original never silently un-crops the served versions. The crop is
        # folded into the fingerprint (as it was at store time), so the
        # recomputed fingerprint matches the stored one and the migration stays
        # idempotent. A nil crop is a no-op centered derive, byte-identical to
        # the pre-crop behaviour.
        crop = image.crop
        fingerprint = content_hash(original, crop)

        with {:ok, rotated} <- Spec.open_rotated(original),
             {:ok, cropped} <- Crop.apply_to(rotated, Crop.parse(crop)),
             :ok <- write_derived_versions(cropped, dir, user, fingerprint, config),
             {:ok, _user} <- persist_fingerprint(image, user, fingerprint, config) do
          :ok
        end
    end
  end

  # A re-derive writes a fresh fingerprint onto both halves: the picture's row
  # in the shared `images` table, which is what every URL is built from, and the
  # member row's column, which the release one step back is still serving from.
  # A picture the backfill has not reached has no row (it came through
  # `Vutuv.Images.member_image/2`'s bridge, whose id is nil), so it costs no
  # statement there — creating one is never a side effect of a deploy.
  defp persist_fingerprint(image, user, fingerprint, config) do
    with {:ok, saved} <-
           user
           |> Ecto.Changeset.change(%{config.fingerprint_field => fingerprint})
           |> Repo.update() do
      Images.sync_fingerprint(image.id, fingerprint)
      {:ok, saved}
    end
  end

  defp dry_run_fingerprinted(user, storage_dir, dir, fingerprint, config) do
    cond do
      fingerprint_converged?(user, dir, fingerprint, config) -> :unchanged
      Originals.locate(storage_dir, [Path.join(dir, "*_original.*")]) -> :ok
      true -> {:skipped, :missing_original}
    end
  end

  # Whether there is a picture here a reader may fetch. The rule belongs to
  # `Vutuv.Images` — it is about `moderation` and `frozen_at`, not about files —
  # so it is stated there and only asked here. Before #2027 it was three
  # separate reads of the member row, and clearing those columns is what made a
  # frozen picture disappear; now `frozen_at` is the off switch itself.
  defp servable?(image), do: Images.servable?(image)

  @doc """
  Removes every stored file for `scope` per `config`: both the served tree
  (`<prefix>/<id>`) and the private original (`originals/<prefix>/<id>`). A
  no-op when nothing is stored. Used when an account is deleted — the DB
  cascade drops the row that names the file, but never the file itself.
  """
  def delete(scope, config) do
    storage_dir = storage_dir(scope, config)
    File.rm_rf(disk_dir(storage_dir))
    File.rm_rf(quarantine_dir(storage_dir))
    Originals.delete(storage_dir)
    :ok
  end

  # Two URL schemes, chosen per row by whether a content fingerprint is stored:
  #
  #   * fingerprinted (scheme B): `<prefix>/<id>/<handle>-<version>-<fp>.avif`.
  #     The handle (the download filename the browser offers) and the content
  #     fingerprint live in the filename itself, so the URL is immutable and
  #     needs no `?v=`. The file on disk has this exact name, so the existing
  #     nginx `alias` (and dev `Plug.Static`) serve it directly — no rewrite.
  #
  #   * legacy: today's `<prefix>/<id>/<stable-or-name-derived>.avif?v=<token>`.
  #     A nil fingerprint means the row has not been migrated to scheme B yet,
  #     so it serves exactly as before. The migration (Vutuv.Uploads.Regenerator)
  #     flips a row from legacy to fingerprinted by writing the new files and
  #     setting the column; nothing here changes until it does.
  defp served_url(%Image{} = image, scope, version, config) do
    case image.fingerprint do
      nil -> legacy_served_url(image.file, scope, version, config)
      fp -> fingerprinted_url(scope, version, fp, config)
    end
  end

  @doc """
  The served filename scheme B writes and serves: `<handle>-<version>-<fp>.avif`.
  One source of truth for both the on-disk write (store/regenerate) and the URL,
  so they always match. The handle is the scope's `username` (filesystem-safe
  by validation, `^[a-z0-9_]+$`); a missing slug degrades to the asset kind.
  """
  def fingerprinted_filename(scope, version, fp, config) do
    "#{handle(scope, config)}-#{version}-#{fp}#{Spec.served_ext()}"
  end

  # The same name with the handle left open, for a tree where nothing can say
  # what the handle is: a takedown hold keeps the name the picture had when it
  # was frozen, which a rename since then has made stale. Beside the builder on
  # purpose — change one and the other has to change with it, or
  # `held_version_path/3` stops finding the file and the case page goes back to
  # drawing a broken image.
  defp fingerprinted_glob(version, fp), do: "*-#{version}-#{fp}#{Spec.served_ext()}"

  defp fingerprinted_url(scope, version, fp, config) do
    "/"
    |> Path.join(storage_dir(scope, config))
    |> Path.join(fingerprinted_filename(scope, version, fp, config))
    |> URI.encode()
  end

  defp handle(scope, config), do: Map.get(scope, :username) || to_string(config.spec_key)

  defp legacy_served_url(file, scope, version, config) do
    local_path =
      Path.join(storage_dir(scope, config), served_filename(scope, version, file, config))

    encoded =
      "/"
      |> Path.join(local_path)
      |> URI.encode()

    encoded <> cache_bust(scope)
  end

  # The served avatar/cover URL is stable and id-scoped (`/avatars/<id>/...`),
  # and nginx caches it hard (`location /avatars/`, `expires 30d`,
  # `Cache-Control: public`). A re-upload overwrites the file in place, so
  # without a cache-buster the URL never changes and the browser keeps serving
  # the *old* image from cache for up to 30 days — "I uploaded a new avatar but
  # can't see it". The token is derived from the scope's `updated_at`, which a
  # successful store always bumps (`Accounts.store_pending_image/4` updates with
  # `force: true`), so the URL changes exactly when the image does and stays
  # cacheable between changes. No `updated_at` (e.g. an unpersisted struct) =>
  # no token.
  defp cache_bust(%{updated_at: updated_at}) when not is_nil(updated_at),
    do: "?v=#{:erlang.phash2(updated_at)}"

  defp cache_bust(_), do: ""

  defp write_derived_versions(rotated, dir, scope, fingerprint, config) do
    Spec.write_all(config.spec_key, rotated, fn spec ->
      Path.join(dir, fingerprinted_filename(scope, spec.name, fingerprint, config))
    end)
  end

  # Which on-disk file backs a served URL. The stable, id-scoped filename
  # (`avatar_thumb.avif`) is authoritative; renaming the profile no longer
  # moves it, because the name is no longer baked into the filename (issue
  # #773). Until the regenerator has re-derived an existing row to the stable
  # name, the pre-#773 name-derived file (`<First Last>_thumb.avif`, or its
  # pre-AVIF extension) keeps resolving (transitional, like the AVIF fallback).
  defp served_filename(scope, version, file, config) do
    dir = disk_dir(storage_dir(scope, config))
    stable = version_filename(config, version, Spec.served_ext())

    if File.exists?(Path.join(dir, stable)) do
      stable
    else
      legacy_name_filename(scope, version, file, dir) || stable
    end
  end

  # The pre-#773 name-derived filename still on disk: `"<First Last>_<version>"`
  # with the served `.avif` or, for a not-yet-AVIF-converted row, the stored
  # upload's extension. A profile that has since been renamed no longer matches
  # its own old file here (that is the bug #773 fixes); the regenerator's
  # re-derive to the stable name is what repairs those, permanently.
  defp legacy_name_filename(scope, version, file, dir) do
    Enum.find_value([Spec.served_ext(), extname(file)], fn ext ->
      candidate = "#{scope}_#{version}#{ext}"
      if File.exists?(Path.join(dir, candidate)), do: candidate
    end)
  end

  defp storage_dir(scope, config), do: "#{config.prefix}/#{scope.id}"

  # Stable and id-scoped: the directory (`<prefix>/<id>`) already isolates the
  # user, so the filename only needs the asset kind + version. No display name,
  # so a rename can never orphan it and an unsanitized name can never escape the
  # directory (both #773).
  defp version_filename(config, version, ext), do: "#{config.spec_key}_#{version}#{ext}"

  # Both pre-fingerprint names at once — the stable `avatar_<version>.avif`
  # above and the pre-#773 `<First Last>_<version>.<ext>` of
  # `legacy_name_filename/4` — for the takedown hold, which has neither the
  # scope nor the config those two build from. The `_<version>.` in the middle
  # is what tells them from a fingerprinted name (`-<version>-`) and from the
  # private `original<ext>`. Beside the builders, so a change to the scheme
  # meets its glob.
  defp legacy_version_glob(version), do: "*_#{version}.*"

  defp extname(value) when is_binary(value) do
    value
    |> strip_query()
    |> Path.extname()
  end

  @doc """
  Whether `file_name`'s extension (case-insensitive) is in `whitelist`. The
  screenshot uploader reuses this with its own wider whitelist.
  """
  def valid_extension?(file_name, whitelist) do
    extension = file_name |> Path.extname() |> String.downcase()
    extension in whitelist
  end

  defp valid_extension?(file_name), do: valid_extension?(file_name, extension_whitelist())

  @doc """
  A fresh unguessable URL token (~128 bits, URL-safe Base64) for the
  token-keyed uploaders (`Vutuv.PostImageStore`, `Vutuv.OrganizationImageStore`,
  `Vutuv.JobPostingImageStore`): the token is both the proxy's lookup key and
  the on-disk directory name, never the row id.
  """
  def gen_token do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc """
  The `store/3` scaffold shared by the token-keyed uploaders
  (`Vutuv.PostImageStore`, `Vutuv.OrganizationImageStore`,
  `Vutuv.JobPostingImageStore`): checks `filename` against `whitelist`
  (a miss returns `{:error, :invalid_file}` without touching the disk),
  creates `dir`, and calls `write_fun.(ext)` — `ext` is the downcased
  extension — to write the derived versions and the original. `{:ok, meta}`
  comes back with the upload's `content_type` merged in; `{:error, _}`
  removes the fresh `dir` again and collapses to `{:error, :invalid_file}`.
  """
  def store_upload(filename, whitelist, dir, write_fun) do
    if valid_extension?(filename, whitelist) do
      ext = filename |> Path.extname() |> String.downcase()
      File.mkdir_p!(dir)

      case write_fun.(ext) do
        {:ok, meta} ->
          {:ok, Map.merge(meta, %{content_type: MIME.from_path(filename)})}

        {:error, _reason} ->
          File.rm_rf(dir)
          {:error, :invalid_file}
      end
    else
      {:error, :invalid_file}
    end
  end

  @doc """
  The one regeneration driver (used by every uploader's `regenerate/2`, which
  `Vutuv.Uploads.Regenerator` calls per DB row): adopts a legacy public
  original into the private tree, re-derives all served versions per the
  current `Vutuv.Uploads.Spec`, and sweeps stale derived files.

  `config`:
    * `:canonical` — the served filenames the current Spec produces in `dir`
    * `:stale_glob` — glob (relative to `dir`) matching every file a past
      pipeline may have left there; matches not in `:canonical` are swept
    * `:legacy_candidates` — globs for where the original lived before the
      private tree existed
    * `:derive` — `fn rotated_image -> :ok | {:error, _} end` writing the
      canonical versions
    * `:opts` — `dry_run:` (report only), `force:` (re-derive even converged
      rows — needed when only quality/resolution changed in the Spec, since
      the canonical filenames stay the same)

  A row is **converged** (returns `:unchanged`) when the original is already
  private, all canonical files exist and nothing stale is left — so a routine
  run (e.g. the deploy hook) is cheap. Returns `:ok` (regenerated),
  `:unchanged`, `{:skipped, :missing_original}` (files left untouched; the
  transitional legacy fallback keeps serving them) or `{:error, reason}`.
  """
  def regenerate_from_original(storage_dir, dir, config) do
    ctx = %{
      storage_dir: storage_dir,
      dir: dir,
      canonical: Keyword.fetch!(config, :canonical),
      stale_glob: Keyword.fetch!(config, :stale_glob),
      candidates: Keyword.fetch!(config, :legacy_candidates),
      derive: Keyword.fetch!(config, :derive)
    }

    opts = Keyword.get(config, :opts, [])

    cond do
      opts[:dry_run] -> dry_run_report(ctx)
      !opts[:force] && converged?(ctx) -> :unchanged
      true -> adopt_and_derive(ctx)
    end
  end

  defp dry_run_report(ctx) do
    cond do
      converged?(ctx) -> :unchanged
      Originals.locate(ctx.storage_dir, ctx.candidates) -> :ok
      true -> {:skipped, :missing_original}
    end
  end

  defp adopt_and_derive(ctx) do
    case Originals.adopt(ctx.storage_dir, ctx.candidates) do
      nil ->
        {:skipped, :missing_original}

      original ->
        File.mkdir_p!(ctx.dir)

        with {:ok, rotated} <- Spec.open_rotated(original),
             :ok <- ctx.derive.(rotated) do
          sweep_stale(ctx)
        end
    end
  end

  defp converged?(ctx) do
    Originals.path(ctx.storage_dir) != nil and
      Enum.all?(ctx.canonical, &File.exists?(Path.join(ctx.dir, &1))) and
      stale_files(ctx) == []
  end

  defp sweep_stale(ctx) do
    for file <- stale_files(ctx), do: File.rm(file)
    :ok
  end

  defp stale_files(ctx) do
    ctx.dir
    |> Path.join(ctx.stale_glob)
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) in ctx.canonical))
  end
end
