defmodule Vutuv.Repo.UpgradePathMigrationTest do
  @moduledoc """
  Guards the integer -> UUID **upgrade** path, which the rest of the suite
  cannot reach. On a from-scratch database the repo's `:binary_id` default makes
  every id a UUID from the very first migration, so a later migration that
  creates a `references/2` FK never collides with its parent — both are UUID.

  A real upgrade is different: the legacy tables are still `bigint` when the
  `post_*` tables are created, because the conversion to UUID
  (`convert_ids_to_uuid_v7`) runs *after* them. A migration that lets its FK
  columns fall back to the `:binary_id` default there builds a UUID column
  pointing at a still-`bigint` parent, and Postgres rejects it with
  `42804 datatype_mismatch` — which is exactly what shipped and broke the dev
  upgrade. The fix: each pre-conversion `post_*` migration probes the live
  `users.id` type and uses bigint ids while legacy.

  This test reproduces that path: it spins up a scratch database holding only
  the legacy `bigint` parents (`users`, `groups`, `tags`) and runs the three
  pre-conversion migrations against it. Pre-fix they raise; post-fix they create
  bigint FK columns (which the conversion migration later turns into UUID along
  with everything else).
  """
  # Not async and not DataCase: this drives its own scratch database and repo,
  # not the SQL Sandbox.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.Postgres, as: PostgresAdapter
  alias Vutuv.UpgradePathTestRepo, as: ScratchRepo

  # {version, module} of every migration that creates a table with a FK to a
  # legacy parent and runs BEFORE convert_ids_to_uuid_v7 (20260607113000).
  @pre_conversion_migrations [
    {20_260_606_105_703, Vutuv.Repo.Migrations.CreatePosts},
    {20_260_606_135_623, Vutuv.Repo.Migrations.CreatePostEngagement},
    {20_260_607_104_046, Vutuv.Repo.Migrations.CreatePostReplies}
  ]

  setup do
    config =
      Vutuv.Repo.config()
      |> Keyword.drop([:pool, :pool_size])
      |> Keyword.merge(
        database: "vutuv_upgrade_path_test#{System.get_env("MIX_TEST_PARTITION")}",
        pool_size: 2
      )

    # A leftover DB from a crashed run would fail storage_up; start clean.
    _ = PostgresAdapter.storage_down(config)
    :ok = PostgresAdapter.storage_up(config)

    Application.put_env(:vutuv, ScratchRepo, config)
    {:ok, pid} = ScratchRepo.start_link(config)
    # Unlink so the repo outlives this test process and is still up when the
    # on_exit teardown stops it (a linked repo is killed with the test process
    # first, and dropping the DB then fails on the lingering connections).
    Process.unlink(pid)

    on_exit(fn ->
      # Stop the repo before dropping: Postgres refuses to drop a DB with live
      # connections.
      try do
        Supervisor.stop(pid, :normal, :infinity)
      catch
        :exit, _ -> :ok
      end

      _ = PostgresAdapter.storage_down(config)
      Application.delete_env(:vutuv, ScratchRepo)
    end)

    # The legacy parents these migrations reference, as bigint — the state a
    # real upgrade is in when the post_* tables are created.
    for table <- ~w(users groups tags) do
      ScratchRepo.query!("CREATE TABLE #{table} (id bigserial PRIMARY KEY)")
    end

    :ok
  end

  test "pre-conversion post_* migrations build bigint FKs against still-bigint legacy parents" do
    # Pre-fix this raises Postgrex 42804 (datatype_mismatch) on the first FK;
    # the assertion that each returns :ok is the regression guard.
    for {version, module} <- @pre_conversion_migrations do
      ensure_loaded!(version, module)
      assert Ecto.Migrator.up(ScratchRepo, version, module, log: false) == :ok
    end

    # Primary keys and every FK to a legacy/new parent must come out bigint, so
    # the later convert_ids_to_uuid_v7 migration can convert them in lockstep.
    assert col_type("posts", "id") == "bigint"
    assert col_type("posts", "user_id") == "bigint"
    assert col_type("post_denials", "post_id") == "bigint"
    assert col_type("post_denials", "group_id") == "bigint"
    assert col_type("post_images", "post_id") == "bigint"
    assert col_type("post_images", "user_id") == "bigint"
    assert col_type("post_tags", "tag_id") == "bigint"
    assert col_type("post_likes", "post_id") == "bigint"
    assert col_type("post_bookmarks", "user_id") == "bigint"
    assert col_type("post_reposts", "post_id") == "bigint"
    assert col_type("post_replies", "parent_post_id") == "bigint"
    assert col_type("post_replies", "parent_author_id") == "bigint"
  end

  defp col_type(table, column) do
    %{rows: [[type]]} =
      ScratchRepo.query!(
        "SELECT data_type FROM information_schema.columns " <>
          "WHERE table_name = $1 AND column_name = $2",
        [table, column]
      )

    type
  end

  # Migration files under priv/ are not part of the compiled app. The `mix test`
  # alias runs `ecto.migrate` first, which loads them, so this is usually a
  # no-op; compile on demand for a standalone `mix test <file>` run.
  defp ensure_loaded!(version, module) do
    unless Code.ensure_loaded?(module) do
      [path] = Path.wildcard(Path.join([File.cwd!(), "priv/repo/migrations", "#{version}_*.exs"]))
      Code.require_file(path)
    end

    module
  end
end
