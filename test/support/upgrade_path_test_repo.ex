defmodule Vutuv.UpgradePathTestRepo do
  @moduledoc """
  A throwaway repo used only by `Vutuv.Repo.UpgradePathMigrationTest` to run
  migrations against a scratch database that starts from the *legacy bigint*
  schema. The normal `Vutuv.Repo` runs the SQL Sandbox against the from-scratch
  (already-UUID) test database, which cannot reproduce the integer -> UUID
  upgrade path. This repo is started with explicit config in the test's setup
  and stopped on exit; it is intentionally not part of `:ecto_repos`.
  """
  use Ecto.Repo, otp_app: :vutuv, adapter: Ecto.Adapters.Postgres
end
