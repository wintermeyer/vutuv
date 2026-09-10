defmodule Vutuv.Repo.CreateTagFollowSourcesTest do
  @moduledoc """
  Covers the backfill half of `create_tag_follow_sources` (issue #2125): every
  follow that existed before the table gets exactly one source, `vutuv`, so
  nothing changes for anybody until they add a server themselves.

  A fresh test database holds no old follows, so the migration's own run here
  would touch nothing — the run that counts is against `vutuv1_dev` (see
  CLAUDE.md). What this file builds is the state the migration meets in
  production: follows written straight into the table, a member's and a page's,
  and one that already carries its source because it was made after the deploy.

  It drives `backfill/1`, the migration's own code, so the two cannot drift.

  `async: false`: the module is loaded from `priv/repo/migrations` with
  `Code.require_file/1`, which is global.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Tags
  alias Vutuv.Tags.TagFollowSource

  @migration Vutuv.Repo.Migrations.CreateTagFollowSources

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      [file] = Path.wildcard("priv/repo/migrations/*_create_tag_follow_sources.exs")
      Code.require_file(file)
    end

    :ok
  end

  test "gives a member's and a page's existing follow the local source" do
    tag = insert(:tag)
    member_follow = insert(:tag_follow, user: insert(:user), tag: tag)
    page_follow = insert(:tag_follow, organization: insert(:organization), tag: tag)

    assert @migration.backfill(Repo) == 2

    assert Tags.tag_follow_sources(member_follow) == ["vutuv"]
    assert Tags.tag_follow_sources(page_follow) == ["vutuv"]
  end

  test "a second run adds nothing" do
    insert(:tag_follow, user: insert(:user), tag: insert(:tag))

    assert @migration.backfill(Repo) == 1
    assert @migration.backfill(Repo) == 0
    assert Repo.aggregate(TagFollowSource, :count) == 1
  end

  test "leaves a follow made after the deploy alone" do
    {:ok, follow} = Tags.follow_tag(insert(:user), insert(:tag))
    {:ok, _} = Tags.add_tag_follow_source(follow, "mastodon.social")

    assert @migration.backfill(Repo) == 0
    assert Tags.tag_follow_sources(follow) == ["vutuv", "mastodon.social"]
  end

  test "mints v7 ids, so the source rows sort by when they were written" do
    tag = insert(:tag)
    for _ <- 1..3, do: insert(:tag_follow, user: insert(:user), tag: tag)

    assert @migration.backfill(Repo) == 3

    ids = Repo.all(from(s in TagFollowSource, select: s.id))
    assert length(ids) == 3

    for id <- ids do
      assert %NaiveDateTime{} = Vutuv.UUIDv7.timestamp(id)
    end
  end
end
