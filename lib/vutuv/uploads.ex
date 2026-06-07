defmodule Vutuv.Uploads do
  @moduledoc """
  The toolset shared by all local-disk uploaders (`Vutuv.Avatar`,
  `Vutuv.Cover`, `Vutuv.Screenshot`, `Vutuv.PostImageStore`): storage-root
  resolution and the one regeneration driver every image type goes through
  (`regenerate_from_original/3`). Private originals live in
  `Vutuv.Uploads.Originals`, version specs and the AVIF encoder in
  `Vutuv.Uploads.Spec`.
  """

  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec

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
