defmodule Vutuv.Uploads.LegacyRelabel do
  @moduledoc """
  Renames the on-disk image directories from their legacy integer id to the new
  UUID after the `convert_ids_to_uuid_v7` migration.

  Image storage is keyed on a DB id: `avatars/<user.id>`, `covers/<user.id>`,
  `screenshots/<url.id>` and their private `originals/` mirrors. When the
  migration changes `users.id`/`urls.id` from integer to UUID, those directories
  keep their old integer names and every URL (which now carries the UUID) points
  at a directory that no longer exists. This task closes that gap.

  The integer ids are gone from the rows by the time this runs, so the migration
  leaves an explicit `legacy_id_map(entity, legacy_id, uuid)` table behind (it
  captures the pairs for `users` and `urls` while both still exist). `run/1`
  reads it; `relabel/2` does the renaming. Both are **idempotent** (a directory
  already named for a UUID is left alone), **never overwrite** (an existing UUID
  target is reported, not clobbered) and **leave directories no row claims
  untouched** (a deleted or renamed user keeps its files, the orphan pass in
  `Vutuv.Uploads.Regenerator` deals with those). Run it **before**
  `regenerate_images` on the cutover deploy.

  post_images are unaffected: they are keyed on an opaque token, not a DB id.

  Run locally via `mix vutuv.images.relabel_legacy_dirs [--dry-run]`; on a
  release via `bin/vutuv eval "Vutuv.Release.relabel_image_dirs()"`.
  """

  alias Vutuv.Repo
  alias Vutuv.Uploads

  # The public trees each entity's integer-id directories live in. Every tree
  # has a private `originals/<tree>` mirror that must move with it.
  @trees %{
    "users" => ~w(avatars covers),
    "urls" => ~w(screenshots)
  }

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  @doc """
  Renames every image directory using the map the conversion migration left in
  `legacy_id_map`. Returns `{:ok, summary}` (see `relabel/2`) or
  `{:error, :no_mapping}` when the table is absent or empty (the migration has
  not run, or there was nothing to convert).
  """
  def run(opts \\ []) do
    case fetch_mapping() do
      {:ok, [_ | _] = mapping} -> {:ok, relabel(mapping, opts)}
      _ -> {:error, :no_mapping}
    end
  end

  @doc """
  Renames the legacy integer-id directories to their UUID for the given
  `mapping` (a list of `{entity, legacy_id, uuid}`), moving each `originals/`
  mirror with the public tree. `dry_run: true` only counts.

  Returns `%{renamed: n, unmapped: n, already_uuid: n, conflict: n}`:

    * `renamed` — moved from integer to UUID
    * `unmapped` — integer dir with no row in the map (deleted/renamed row);
      left in place for the regenerator's orphan pass
    * `already_uuid` — already named for a UUID (a prior run)
    * `conflict` — the UUID target already existed; left untouched, not clobbered
  """
  def relabel(mapping, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    maps = build_maps(mapping)
    empty = %{renamed: 0, unmapped: 0, already_uuid: 0, conflict: 0}

    for {entity, prefixes} <- @trees,
        idmap = Map.get(maps, entity, %{}),
        prefix <- prefixes,
        base <- [prefix, Path.join("originals", prefix)],
        reduce: empty do
      acc -> rename_tree(Uploads.disk_dir(base), idmap, dry_run, acc)
    end
  end

  defp rename_tree(dir, idmap, dry_run, acc) do
    case File.ls(dir) do
      {:error, _} -> acc
      {:ok, entries} -> Enum.reduce(entries, acc, &rename_entry(&1, dir, idmap, dry_run, &2))
    end
  end

  defp rename_entry(name, dir, idmap, dry_run, acc) do
    path = Path.join(dir, name)
    uuid = Map.get(idmap, name)

    cond do
      not File.dir?(path) -> acc
      name =~ @uuid_re -> bump(acc, :already_uuid)
      uuid == nil -> bump(acc, :unmapped)
      true -> move(path, Path.join(dir, uuid), dry_run, acc)
    end
  end

  defp move(src, dst, dry_run, acc) do
    cond do
      File.exists?(dst) ->
        log("  CONFLICT #{src} -> #{dst} (target exists, left in place)")
        bump(acc, :conflict)

      dry_run ->
        bump(acc, :renamed)

      true ->
        File.rename!(src, dst)
        bump(acc, :renamed)
    end
  end

  defp bump(acc, key), do: Map.update!(acc, key, &(&1 + 1))

  defp build_maps(mapping) do
    mapping
    |> Enum.group_by(fn {entity, _id, _uuid} -> entity end)
    |> Map.new(fn {entity, rows} ->
      {entity, Map.new(rows, fn {_e, legacy_id, uuid} -> {to_string(legacy_id), uuid} end)}
    end)
  end

  defp fetch_mapping do
    if table_exists?() do
      %{rows: rows} = Repo.query!("SELECT entity, legacy_id, uuid::text FROM legacy_id_map")
      {:ok, Enum.map(rows, fn [entity, legacy_id, uuid] -> {entity, legacy_id, uuid} end)}
    else
      :error
    end
  end

  defp table_exists? do
    %{rows: [[exists]]} = Repo.query!("SELECT to_regclass('public.legacy_id_map') IS NOT NULL")
    exists
  end

  # stdout progress for operators; the quiet-flag logic lives once in
  # Vutuv.Uploads.log/1.
  defp log(message), do: Vutuv.Uploads.log(message)
end
