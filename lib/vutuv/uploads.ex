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
  """

  alias Vutuv.Repo
  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @extension_whitelist ~w(.jpg .jpeg .png)

  # Length (hex chars) of the content fingerprint baked into served filenames.
  # 12 hex = 48 bits, matching Vutuv.Screenshot — collision-safe within a single
  # id-scoped directory (one image's versions), which is all that shares a dir.
  @hash_length 12

  @typedoc """
  Per-uploader layout passed to the shared `store/2`, `url/3` and
  `regenerate/3` pipeline (`Vutuv.Avatar` and `Vutuv.Cover` differ only in
  these four knobs):

    * `:spec_key` — the `Vutuv.Uploads.Spec.versions/1` key (`:avatar | :cover`)
    * `:prefix` — the served-tree storage prefix (`"avatars"` / `"covers"`)
    * `:default_version` — the version `url/3` serves when none is given
    * `:stale_glob` — the `regenerate/3` sweep glob (relative to the dir)
  """
  @type uploader_config :: %{
          spec_key: atom(),
          prefix: String.t(),
          default_version: atom(),
          stale_glob: String.t()
        }

  @doc """
  The absolute storage root, configured per environment via
  `config :vutuv, :uploads_dir_prefix`. Empty in dev/test and
  `/srv/legacy-vutuv` in production.
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
  Drops a legacy `"?<timestamp>"` cache-busting suffix from a stored filename.
  """
  def strip_query(value) when is_binary(value), do: String.replace(value, ~r/\?\d+$/, "")

  @doc """
  Stores every derived version for `{upload, scope}` per `config` and returns
  `{:ok, original_file_name, fingerprint}` — the verbatim upload name and the
  content fingerprint (`sha256(original)[0..#{@hash_length - 1}]`) the caller
  keeps in its columns — or `{:error, :invalid_file}` when the extension is not
  whitelisted **or the file cannot be decoded as an image** (corrupt/truncated
  uploads used to crash the request with a `MatchError`).

  The served files are written under the fingerprinted scheme-B name
  `<handle>-<version>-<fingerprint>.avif`, so a fresh upload is immediately on
  the new scheme (its URL carries the fingerprint, no `?v=`).

  Order matters: the derived versions decode the image, so a corrupt or
  truncated file fails before anything on disk is touched; only then are the
  prior versions cleared, the new ones written, and the original copied
  (privately). Clearing prior versions keeps exactly one image set per dir, so a
  re-upload never accumulates stale fingerprinted/legacy files.
  """
  def store({%Plug.Upload{} = upload, scope}, config) do
    if valid_extension?(upload.filename) do
      ext = Path.extname(upload.filename)
      storage_dir = storage_dir(scope, config)
      dir = disk_dir(storage_dir)
      File.mkdir_p!(dir)
      fingerprint = content_hash(upload.path)

      with {:ok, rotated} <- Spec.open_rotated(upload.path),
           :ok <- clear_public_versions(dir),
           :ok <- write_derived_versions(rotated, dir, scope, fingerprint, config),
           :ok <- Originals.store(storage_dir, upload.path, ext) do
        {:ok, upload.filename, fingerprint}
      else
        {:error, _reason} -> {:error, :invalid_file}
      end
    else
      {:error, :invalid_file}
    end
  end

  # The first 12 hex of the SHA-256 of the uploaded bytes — the content
  # fingerprint baked into the served filename. Hashing the **original** (not a
  # derived version) makes it deterministic, so a regeneration of the same image
  # produces the same name (idempotent migration) and an identical re-upload
  # reuses the same URL.
  defp content_hash(path) do
    :sha256
    |> :crypto.hash(File.read!(path))
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
  Root-relative, URI-encoded URL for a given `{file, scope}` and served
  version per `config`. Returns `nil` when the user has no file or for
  `:original` (the original is never URL-addressable).
  """
  def url({file, scope}, version, config) do
    cond do
      is_nil(file) -> nil
      version == :original -> nil
      true -> served_url(file, scope, version, config)
    end
  end

  @doc """
  The on-disk path of a served version (the `.avif`, or the transitional
  pre-AVIF file), or `nil` when none exists. Lets the avatar link-preview
  JPEG (`Vutuv.Avatar.og_jpeg/1`) derive from the best available image
  when no private original was kept (legacy uploads predate the kept
  originals).
  """
  def version_path({file, scope}, version, config) do
    if file do
      dir = disk_dir(storage_dir(scope, config))

      name =
        case fingerprint(scope, config) do
          nil -> served_filename(scope, version, file, config)
          fp -> fingerprinted_filename(scope, version, fp, config)
        end

      path = Path.join(dir, name)
      if File.exists?(path), do: path
    end
  end

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
  def regenerate(user, opts, config) do
    storage_dir = storage_dir(user, config)
    dir = disk_dir(storage_dir)
    fingerprint = Map.get(user, config.fingerprint_field)

    cond do
      opts[:dry_run] ->
        dry_run_fingerprinted(user, storage_dir, dir, fingerprint, config)

      fingerprint_converged?(user, dir, fingerprint, config) and
          not Keyword.get(opts, :force, false) ->
        :unchanged

      true ->
        migrate_to_fingerprinted(user, storage_dir, dir, config)
    end
  end

  @doc """
  Re-derives the fingerprinted files under `user`'s **current** handle after a
  username change, so the slug-in-the-filename URL keeps resolving. A no-op for a
  row not yet on the fingerprinted scheme (its legacy URL is name/id-based, not
  slug-based). Works off the private original, so it never depends on the
  old-handle files still being present. See `Accounts.update_active_slug/2`.
  """
  def reslug(user, config) do
    if Map.get(user, config.fingerprint_field) do
      regenerate(user, [force: true], config)
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
  def sweep_legacy(user, opts, config) do
    fingerprint = Map.get(user, config.fingerprint_field)
    dir = disk_dir(storage_dir(user, config))

    cond do
      is_nil(fingerprint) -> :unchanged
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

  defp migrate_to_fingerprinted(user, storage_dir, dir, config) do
    case Originals.adopt(storage_dir, [Path.join(dir, "*_original.*")]) do
      nil ->
        {:skipped, :missing_original}

      original ->
        File.mkdir_p!(dir)
        fingerprint = content_hash(original)

        with {:ok, rotated} <- Spec.open_rotated(original),
             :ok <- write_derived_versions(rotated, dir, user, fingerprint, config),
             {:ok, _user} <- persist_fingerprint(user, fingerprint, config) do
          :ok
        end
    end
  end

  defp persist_fingerprint(user, fingerprint, config) do
    user
    |> Ecto.Changeset.change(%{config.fingerprint_field => fingerprint})
    |> Repo.update()
  end

  defp dry_run_fingerprinted(user, storage_dir, dir, fingerprint, config) do
    cond do
      fingerprint_converged?(user, dir, fingerprint, config) -> :unchanged
      Originals.locate(storage_dir, [Path.join(dir, "*_original.*")]) -> :ok
      true -> {:skipped, :missing_original}
    end
  end

  @doc """
  Removes every stored file for `scope` per `config`: both the served tree
  (`<prefix>/<id>`) and the private original (`originals/<prefix>/<id>`). A
  no-op when nothing is stored. Used when an account is deleted — the DB
  cascade drops the row that names the file, but never the file itself.
  """
  def delete(scope, config) do
    storage_dir = storage_dir(scope, config)
    File.rm_rf(disk_dir(storage_dir))
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
  defp served_url(file, scope, version, config) do
    case fingerprint(scope, config) do
      nil -> legacy_served_url(file, scope, version, config)
      fp -> fingerprinted_url(scope, version, fp, config)
    end
  end

  @doc """
  The served filename scheme B writes and serves: `<handle>-<version>-<fp>.avif`.
  One source of truth for both the on-disk write (store/regenerate) and the URL,
  so they always match. The handle is the scope's `active_slug` (filesystem-safe
  by validation, `^[a-z0-9_]+$`); a missing slug degrades to the asset kind.
  """
  def fingerprinted_filename(scope, version, fp, config) do
    "#{handle(scope, config)}-#{version}-#{fp}#{Spec.served_ext()}"
  end

  defp fingerprinted_url(scope, version, fp, config) do
    "/"
    |> Path.join(storage_dir(scope, config))
    |> Path.join(fingerprinted_filename(scope, version, fp, config))
    |> URI.encode()
  end

  defp handle(scope, config), do: Map.get(scope, :active_slug) || to_string(config.spec_key)

  # The fingerprint stored on the scope for this asset (`:avatar_fingerprint` /
  # `:cover_fingerprint`), or nil when the row predates scheme B or the config
  # opts out (`:fingerprint_field` absent).
  defp fingerprint(scope, config) do
    case Map.get(config, :fingerprint_field) do
      nil -> nil
      field -> Map.get(scope, field)
    end
  end

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
    Enum.reduce_while(Spec.versions(config.spec_key), :ok, fn spec, :ok ->
      dest = Path.join(dir, fingerprinted_filename(scope, spec.name, fingerprint, config))

      case Spec.write_derived(spec, rotated, dest) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
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

  defp extname(value) when is_binary(value) do
    value
    |> strip_query()
    |> Path.extname()
  end

  defp valid_extension?(file_name) do
    extension = file_name |> Path.extname() |> String.downcase()
    extension in @extension_whitelist
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
