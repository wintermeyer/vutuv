defmodule Vutuv.Release do
  @moduledoc """
  Release tasks for an assembled `mix release`, where Mix is not available.

  Run migrations during deploy with:

      bin/vutuv eval "Vutuv.Release.migrate()"
  """
  alias Vutuv.Uploads.LegacyRelabel
  alias Vutuv.Uploads.LegacySweeper
  alias Vutuv.Uploads.Regenerator

  @app :vutuv

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Grants admin rights to the member behind a username or email address — how a
  production installation mints its (first) admin (`Vutuv.Accounts.promote_admin/1`;
  the flag is never settable through a form or the API):

      bin/vutuv eval 'Vutuv.Release.promote_admin("stefan.wintermeyer")'
  """
  def promote_admin(identifier) when is_binary(identifier) do
    load_app()
    [repo] = repos()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, fn _repo ->
        case Vutuv.Accounts.promote_admin(identifier) do
          {:ok, user} ->
            IO.puts("@#{user.username} is an admin now.")

          {:error, :not_found} ->
            IO.puts(
              "No member found for #{inspect(identifier)} (looked up as @handle and email)."
            )

          {:error, changeset} ->
            IO.puts("Could not promote #{inspect(identifier)}: #{inspect(changeset.errors)}")
        end
      end)

    :ok
  end

  @doc """
  Re-derives every served image version from the private originals per the
  current `Vutuv.Uploads.Spec` (see `Vutuv.Uploads.Regenerator`). Safe to run
  while the app serves traffic (only the repo is started — no port binding):

      bin/vutuv eval "Vutuv.Release.regenerate_images()"
      bin/vutuv eval "Vutuv.Release.regenerate_images(dry_run: true)"
      bin/vutuv eval "Vutuv.Release.regenerate_images(only: :avatars)"
  """
  def regenerate_images(opts \\ []) do
    load_app()
    {:ok, _} = Application.ensure_all_started(:image)

    [repo] = repos()

    {:ok, summary, _apps} =
      Ecto.Migrator.with_repo(repo, fn _repo -> Regenerator.run(opts) end)

    summary
  end

  @doc """
  Deletes the legacy avatar/cover files the regenerator kept during the expand
  phase — the **contract** step of the fingerprint migration (see
  `Vutuv.Uploads.LegacySweeper`). Run this **only once** the fingerprinted
  scheme is confirmed healthy in production; it is never part of the deploy:

      bin/vutuv eval "Vutuv.Release.sweep_legacy_images(dry_run: true)"
      bin/vutuv eval "Vutuv.Release.sweep_legacy_images()"
  """
  def sweep_legacy_images(opts \\ []) do
    load_app()

    [repo] = repos()

    {:ok, summary, _apps} =
      Ecto.Migrator.with_repo(repo, fn _repo -> LegacySweeper.run(opts) end)

    summary
  end

  @doc """
  Renames the on-disk image directories from their legacy integer id to the new
  UUID after the `convert_ids_to_uuid_v7` migration, using the `legacy_id_map`
  table that migration leaves behind (see `Vutuv.Uploads.LegacyRelabel`). Run
  this **once, before `regenerate_images/1`**, on the UUID cutover deploy:

      bin/vutuv eval "Vutuv.Release.relabel_image_dirs()"
      bin/vutuv eval "Vutuv.Release.relabel_image_dirs(dry_run: true)"

  Returns `{:ok, summary}` or `{:error, :no_mapping}` (table absent/empty).
  """
  def relabel_image_dirs(opts \\ []) do
    load_app()

    [repo] = repos()

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(repo, fn _repo -> LegacyRelabel.run(opts) end)

    result
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
