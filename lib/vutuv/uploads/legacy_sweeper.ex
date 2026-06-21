defmodule Vutuv.Uploads.LegacySweeper do
  @moduledoc """
  The **contract** half of the avatar/cover fingerprint migration: deletes the
  legacy files left behind by `Vutuv.Uploads.Regenerator` (which deliberately
  keeps them during the *expand* phase so the previous release and a rollback
  keep serving them). Run this only once the fingerprinted scheme is confirmed
  healthy in production — it is never wired into the deploy, always a deliberate
  step (`mix vutuv.images.sweep_legacy` / `Vutuv.Release.sweep_legacy_images()`).

  DB-driven and **safe by construction**: it visits only rows already on the
  fingerprinted scheme (`*_fingerprint` set), and per row deletes only the files
  that are not the current fingerprinted versions — and only when all of those
  versions are present (`Vutuv.Uploads.sweep_legacy/3`). A row still on the
  legacy scheme is never touched. Idempotent.

  Returns a summary like
  `%{avatars: %{rows: 10, files_removed: 32, skipped: 1}, covers: %{…}}`.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Repo

  @types ~w(avatars covers)a

  def types, do: @types

  def run(opts \\ []) do
    types =
      case Keyword.get(opts, :only) do
        nil -> @types
        type when type in @types -> [type]
      end

    for type <- types, into: %{}, do: {type, run_type(type, opts)}
  end

  defp run_type(type, opts) do
    rows = rows(type)

    log(
      "#{type}: #{length(rows)} fingerprinted row(s)#{if opts[:dry_run], do: " — dry run", else: ""}"
    )

    rows
    |> Task.async_stream(&sweep(type, &1, opts),
      max_concurrency: System.schedulers_online(),
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce(%{rows: 0, files_removed: 0, skipped: 0}, fn {:ok, result}, acc ->
      case result do
        {kind, names} when kind in [:swept, :dry_run] ->
          %{acc | rows: acc.rows + 1, files_removed: acc.files_removed + length(names)}

        :unchanged ->
          %{acc | skipped: acc.skipped + 1}
      end
    end)
    |> tap(fn t ->
      log(
        "#{type}: #{t.rows} row(s) swept, #{t.files_removed} file(s) removed, #{t.skipped} skipped"
      )
    end)
  end

  defp sweep(:avatars, user, opts), do: Vutuv.Avatar.sweep_legacy(user, opts)
  defp sweep(:covers, user, opts), do: Vutuv.Cover.sweep_legacy(user, opts)

  defp rows(:avatars), do: Repo.all(from(u in User, where: not is_nil(u.avatar_fingerprint)))
  defp rows(:covers), do: Repo.all(from(u in User, where: not is_nil(u.cover_fingerprint)))

  # The quiet-flag logic lives once in Vutuv.Uploads.log/1.
  defp log(message), do: Vutuv.Uploads.log(message)
end
