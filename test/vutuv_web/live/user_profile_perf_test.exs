defmodule VutuvWeb.UserProfilePerfTest do
  @moduledoc """
  Query-count regression tests for the profile page (`/:slug`): the Beiträge
  card's action bars must read from ONE batched engagement query per render
  (`Posts.post_engagement_map/2`), never one query per shown card — the exact
  N+1 the feed already guards against in `post_feed_live_test.exs`.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Posts

  # The action-bar engagement SELECT is the only query built from this
  # hand-written fragment, so its text is a stable signature.
  @engagement_query ~r/post_likes l WHERE l\.post_id/

  test "profile engagement is one batched query, pinned post and thread included", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    {:ok, pinned} = Posts.create_post(user, %{body: "the showcased post"})
    {:ok, _} = Posts.pin_to_profile(user, pinned)

    {:ok, parent} = Posts.create_post(user, %{body: "a post worth answering"})
    {:ok, _reply} = Posts.create_reply(user, parent, %{body: "answering myself"})
    {:ok, _} = Posts.create_post(user, %{body: "one more post"})

    {conn, engagement_queries} =
      Vutuv.QueryCounter.count_queries(
        fn -> get(conn, ~p"/#{user.username}") end,
        matching: @engagement_query
      )

    assert html_response(conn, 200) =~ "the showcased post"

    # The timeline preview (3 entries, one nesting its thread parent) plus the
    # pinned post used to each fire their own engagement query on mount.
    assert engagement_queries == 1,
           "expected the profile to batch engagement into one query, got #{engagement_queries}"
  end

  test "all profile counts run as one union query", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, _} = Posts.create_post(user, %{body: "counted post"})

    # The merged counts union is the only statement that counts both a profile
    # section (user_tags) and the social graph (follows) in one query; the
    # section totals, the three social counts and the posts total used to be
    # three separate round trips per mount.
    {conn, union_queries} =
      Vutuv.QueryCounter.count_queries(
        fn -> get(conn, ~p"/#{user.username}") end,
        matching: ~r/FROM "user_tags"[\s\S]*UNION ALL[\s\S]*FROM "follows"/
      )

    assert html_response(conn, 200) =~ "counted post"
    assert union_queries == 1

    # And the standalone count shapes it replaced are gone from the mount.
    {_conn, standalone_social_counts} =
      Vutuv.QueryCounter.count_queries(
        fn -> recycle(conn) |> get(~p"/#{user.username}") end,
        matching: ~r/^SELECT count\(f0\."id"\) FROM "follows"/
      )

    assert standalone_social_counts == 0
  end

  describe "dead-render → socket-mount handoff" do
    # These tests count queries globally during the connect window (the
    # LiveView process + Ecto's parallel preload tasks), so this module must
    # stay sync (the ConnCase default) — an async neighbour's queries would
    # land in the window.
    test "the connected mount reuses the dead render's work", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _} = Posts.create_post(user, %{body: "handoff post"})

      # The dead render (stashes the payload)...
      conn = get(conn, ~p"/#{user.username}")
      assert html_response(conn, 200) =~ "handoff post"

      # ...then the connect takes it: only the socket's own auth and the
      # shell's badge queries remain.
      {{:ok, _view, hit_html}, hit} =
        Vutuv.QueryCounter.count_queries_global(fn -> live(conn) end)

      assert hit_html =~ "handoff post"

      # A second connect on the same rendered page finds the stash consumed
      # (single-use) and must full-load — still correct, just the slow path.
      {{:ok, _view, miss_html}, miss} =
        Vutuv.QueryCounter.count_queries_global(fn -> live(conn) end)

      assert miss_html =~ "handoff post"

      assert hit <= 15, "handoff-hit connect ran #{hit} queries; the handoff was not used"

      assert miss >= hit + 20,
             "consumed-stash connect ran #{miss} vs hit #{hit}; full-load fallback missing?"
    end

    test "an anonymous visitor never uses the handoff and still full-loads", %{conn: conn} do
      owner = insert(:user, email_confirmed?: true)
      {:ok, _} = Posts.create_post(owner, %{body: "public post"})

      conn = get(conn, ~p"/#{owner.username}")

      {{:ok, _view, html}, connected} =
        Vutuv.QueryCounter.count_queries_global(fn -> live(conn) end)

      # The fallback path must really run: nothing is stashed for an
      # anonymous viewer, so the connect loads the whole profile itself.
      assert html =~ "public post"
      assert connected > 20
    end
  end

  test "profile query count does not grow with post count", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    {:ok, first} = Posts.create_post(user, %{body: "post 1"})
    {:ok, _} = Posts.pin_to_profile(user, first)

    {_, few} = Vutuv.QueryCounter.count_queries(fn -> get(conn, ~p"/#{user.username}") end)

    for n <- 2..5, do: {:ok, _} = Posts.create_post(user, %{body: "post #{n}"})

    {_, many} =
      Vutuv.QueryCounter.count_queries(fn -> recycle(conn) |> get(~p"/#{user.username}") end)

    assert many <= few + 1,
           "profile query count grew from #{few} to #{many}; engagement is not batched"
  end
end
