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

  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

  @extension_whitelist ~w(.jpg .jpeg .png)

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
  `{:ok, original_file_name}` (the verbatim upload name the caller keeps in its
  column), or `{:error, :invalid_file}` when the extension is not whitelisted
  **or the file cannot be decoded as an image** (corrupt/truncated uploads used
  to crash the request with a `MatchError`).

  The derived versions go first: they decode the image, so a corrupt or
  truncated file fails before anything is written; the original is only copied
  (privately) after a successful decode.
  """
  def store({%Plug.Upload{} = upload, scope}, config) do
    if valid_extension?(upload.filename) do
      ext = Path.extname(upload.filename)
      dir = disk_dir(storage_dir(scope, config))
      File.mkdir_p!(dir)

      with {:ok, rotated} <- Spec.open_rotated(upload.path),
           :ok <- write_derived_versions(rotated, scope, dir, config),
           :ok <- Originals.store(storage_dir(scope, config), upload.path, ext) do
        {:ok, upload.filename}
      else
        {:error, _reason} -> {:error, :invalid_file}
      end
    else
      {:error, :invalid_file}
    end
  end

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
      path = Path.join(dir, served_filename(scope, version, file, config))
      if File.exists?(path), do: path
    end
  end

  @doc """
  Re-derives the served versions from the original per the current
  `Vutuv.Uploads.Spec` and `config`'s layout — see
  `regenerate_from_original/3`. Used by `Vutuv.Uploads.Regenerator`.
  """
  def regenerate(user, opts, config) do
    dir = disk_dir(storage_dir(user, config))

    regenerate_from_original(storage_dir(user, config), dir,
      canonical: canonical_filenames(user, config),
      stale_glob: config.stale_glob,
      legacy_candidates: [Path.join(dir, "*_original.*")],
      derive: &write_derived_versions(&1, user, dir, config),
      opts: opts
    )
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

  defp served_url(file, scope, version, config) do
    local_path =
      Path.join(storage_dir(scope, config), served_filename(scope, version, file, config))

    "/"
    |> Path.join(local_path)
    |> URI.encode()
  end

  defp write_derived_versions(rotated, scope, dir, config) do
    Enum.reduce_while(Spec.versions(config.spec_key), :ok, fn spec, :ok ->
      dest = Path.join(dir, version_filename(scope, spec.name, Spec.served_ext()))

      case Spec.write_derived(spec, rotated, dest) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp canonical_filenames(scope, config) do
    for spec <- Spec.versions(config.spec_key),
        do: version_filename(scope, spec.name, Spec.served_ext())
  end

  # The .avif is authoritative; until the regeneration has run, a pre-AVIF
  # derived file with the stored filename's extension keeps resolving.
  # Transitional — remove together with `Spec.legacy_exts/0`.
  defp served_filename(scope, version, file, config) do
    avif = version_filename(scope, version, Spec.served_ext())

    if File.exists?(Path.join(disk_dir(storage_dir(scope, config)), avif)) do
      avif
    else
      legacy_filename(scope, version, file, config) || avif
    end
  end

  defp legacy_filename(scope, version, file, config) do
    candidate = version_filename(scope, version, extname(file))
    if File.exists?(Path.join(disk_dir(storage_dir(scope, config)), candidate)), do: candidate
  end

  defp storage_dir(scope, config), do: "#{config.prefix}/#{scope.id}"

  defp version_filename(scope, version, ext), do: "#{scope}_#{version}#{ext}"

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
