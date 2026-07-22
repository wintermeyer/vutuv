defmodule Vutuv.Uploads.Regenerator do
  @moduledoc """
  Re-derives every served image version from the kept originals — the tool
  that makes a format/quality change in `Vutuv.Uploads.Spec` real for
  existing data, and the one-shot migration into the private `originals/`
  tree.

  **DB-driven** (the rows know which images exist and what the stored
  filename/hash is; walking the filesystem would re-derive orphans and could
  not rebuild name-based avatar files reliably). For every row the uploader's
  `regenerate/2` adopts a legacy public original into the private tree,
  re-derives all served versions per the current Spec, and sweeps stale
  derived files. Idempotent: re-running converges on the same files.

  A row already on the current Spec counts as `unchanged` and is not touched,
  so a routine run (the deploy hook) is cheap; `force: true` re-derives those
  too — needed when only quality/resolution changed in the Spec, because the
  canonical filenames stay the same. A row whose original is missing is
  **skipped with a warning** — its existing derived files are left untouched
  (they keep serving through the transitional legacy fallback) so the
  migration can never destroy a row's only image data.

  A full run ends with the **orphan pass**: original-pattern files still in a
  public tree after the row pass belong to no DB row (deleted user, cleared
  avatar) — they are moved into the private tree so no original stays
  downloadable, ever. Orphaned *derived* files are left alone.

  Run locally via `mix vutuv.images.regenerate [--only TYPE] [--dry-run]
  [--force]`; on a release via
  `bin/vutuv eval "Vutuv.Release.regenerate_images()"`. Returns a summary map
  like `%{avatars: %{regenerated: 10, unchanged: 5, skipped: 1, failed: 0},
  ..., orphan_originals: %{moved: 2}}`.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Posts.PostImage
  alias Vutuv.Profiles.Qualification
  alias Vutuv.Profiles.Url
  alias Vutuv.Repo
  alias Vutuv.Uploads.Originals

  @types ~w(avatars covers screenshots post_images job_posting_images qualification_documents)a

  # Where each public tree may still hold an original-pattern file (the
  # pre-private-tree layouts). Scanned by the final orphan pass.
  @orphan_globs [
    {"avatars", "*/*_original.*"},
    {"covers", "*/*_original.*"},
    {"screenshots", "*/original-*"},
    {"post_images", "*/original.*"}
  ]

  def types, do: @types ++ [:orphans]

  def run(opts \\ []) do
    only = Keyword.get(opts, :only)

    types =
      case only do
        nil -> @types
        :orphans -> []
        type when type in @types -> [type]
      end

    row_opts = Keyword.take(opts, [:dry_run, :force])
    summary = for type <- types, into: %{}, do: {type, run_type(type, row_opts)}

    # The orphan pass runs after the row pass: any original-pattern file still
    # public at that point belongs to no DB row (deleted user, cleared avatar)
    # — the row pass has already adopted every claimed one.
    if only in [nil, :orphans] do
      Map.put(summary, :orphan_originals, sweep_orphan_originals(row_opts[:dry_run]))
    else
      summary
    end
  end

  defp run_type(type, row_opts) do
    rows = rows(type)
    log("#{type}: #{length(rows)} row(s)#{if row_opts[:dry_run], do: " — dry run", else: ""}")

    rows
    |> Task.async_stream(&regenerate(type, &1, row_opts),
      max_concurrency: System.schedulers_online(),
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce(
      %{regenerated: 0, unchanged: 0, skipped: 0, failed: 0},
      fn {:ok, {row_id, result}}, acc ->
        case result do
          :ok ->
            %{acc | regenerated: acc.regenerated + 1}

          :unchanged ->
            %{acc | unchanged: acc.unchanged + 1}

          {:skipped, :missing_original} ->
            log("  WARN #{type} #{row_id}: original missing, skipped (files untouched)")
            %{acc | skipped: acc.skipped + 1}

          {:error, reason} ->
            log("  FAIL #{type} #{row_id}: #{inspect(reason)}")
            %{acc | failed: acc.failed + 1}
        end
      end
    )
    |> tap(fn tally ->
      log(
        "#{type}: #{tally.regenerated} regenerated, #{tally.unchanged} unchanged, " <>
          "#{tally.skipped} skipped, #{tally.failed} failed"
      )
    end)
  end

  # Never let one bad row (a raise in file handling) abort the whole run —
  # it becomes a FAIL in the tally instead.
  defp regenerate(type, row, row_opts) do
    {row_id(type, row), do_regenerate(type, row, row_opts)}
  rescue
    exception -> {row_id(type, row), {:error, exception}}
  end

  defp do_regenerate(:avatars, user, opts), do: Vutuv.Avatar.regenerate(user, opts)
  defp do_regenerate(:covers, user, opts), do: Vutuv.Cover.regenerate(user, opts)
  defp do_regenerate(:screenshots, url, opts), do: Vutuv.Screenshot.regenerate(url, opts)
  defp do_regenerate(:post_images, image, opts), do: Vutuv.PostImageStore.regenerate(image, opts)

  defp do_regenerate(:job_posting_images, image, opts),
    do: Vutuv.JobPostingImageStore.regenerate(image, opts)

  defp do_regenerate(:qualification_documents, qualification, opts),
    do: Vutuv.QualificationDocument.regenerate(qualification.id, opts)

  # Originals that no DB row claims must still never stay publicly
  # downloadable: move them into the private tree. Derived files of unknown
  # rows are left alone — nothing serves them, and deleting data without a
  # row to vouch for it is not this tool's call.
  defp sweep_orphan_originals(dry_run) do
    log("orphaned public originals#{if dry_run, do: " — dry run", else: ""}")

    moved =
      for {tree, glob} <- @orphan_globs,
          file <- Path.wildcard(Path.join(Vutuv.Uploads.disk_dir(tree), glob)),
          reduce: 0 do
        count ->
          log("  ORPHAN #{file} -> private")
          unless dry_run, do: move_orphan(tree, file)
          count + 1
      end

    log("orphaned public originals: #{moved} moved")
    %{moved: moved}
  end

  defp move_orphan(tree, file) do
    storage_dir = Path.join(tree, file |> Path.dirname() |> Path.basename())

    if Originals.path(storage_dir) do
      # The canonical slot is taken (an older upload of the same scope):
      # keep the bytes privately under a non-colliding name.
      dest_dir = Originals.dir(storage_dir)
      File.mkdir_p!(dest_dir)
      File.rename!(file, Path.join(dest_dir, "orphan-#{Path.basename(file)}"))
    else
      Originals.store(storage_dir, file, Path.extname(file))
      File.rm!(file)
    end
  end

  defp rows(:avatars), do: Repo.all(from(u in User, where: not is_nil(u.avatar)))
  defp rows(:covers), do: Repo.all(from(u in User, where: not is_nil(u.cover_photo)))
  defp rows(:screenshots), do: Repo.all(from(u in Url, where: not is_nil(u.screenshot)))
  defp rows(:post_images), do: Repo.all(PostImage)
  defp rows(:job_posting_images), do: Repo.all(Vutuv.Jobs.JobPostingImage)

  defp rows(:qualification_documents),
    do: Repo.all(from(q in Qualification, where: not is_nil(q.document)))

  defp row_id(:post_images, image), do: image.token
  defp row_id(:job_posting_images, image), do: image.token
  defp row_id(_type, row), do: row.id

  # Operator stdout progress (mix task / `bin/vutuv eval`); the quiet-flag logic
  # lives once in Vutuv.Uploads.log/1.
  defp log(message), do: Vutuv.Uploads.log(message)
end
