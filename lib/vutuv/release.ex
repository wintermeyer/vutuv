defmodule Vutuv.Release do
  @moduledoc """
  Release tasks for an assembled `mix release`, where Mix is not available.

  Run migrations during deploy with:

      bin/vutuv eval "Vutuv.Release.migrate()"
  """
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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
