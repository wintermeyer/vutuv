defmodule Vutuv.FediverseRemotePostsSourceTest do
  @moduledoc """
  The feed's remote-posts source across **several** followed accounts at once.

  It used to reach them through a join to `fediverse_follows`, which left
  Postgres no way to walk the feed in time order: it read every cached post of
  every account the viewer follows and top-N-sorted the lot (3,981 rows and
  4,180 buffers for 31, measured on the production copy, 2026-08-31). The follow
  set is now read first and handed to the query as two constant id lists —
  accepted follows, which see everything, and pending ones, which see only open
  audiences — so the planner can pick a plan per viewer.

  The existing suite (`fediverse_remote_posts_test.exs`) already pins what one
  account may show whom. What is new here is everything the join used to do
  implicitly across **many** accounts: no duplicates, one merged order rather
  than per-account runs, and the two states applied to the right accounts.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  defp member, do: insert(:activated_user, fediverse_followers?: true)

  defp account(handle) do
    Repo.insert!(%RemoteAccount{
      actor_uri: "https://social.example/users/#{handle}",
      host: "social.example",
      handle: handle,
      name: handle,
      inbox_uri: "https://social.example/users/#{handle}/inbox"
    })
  end

  defp follow(user, account, state \\ "accepted", muted \\ false) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: state,
      muted: muted,
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{account.id}"
    })
  end

  # `minutes_ago` rather than a literal, so the merged order is the thing
  # asserted and not the clock.
  defp post(account, text, minutes_ago, audience \\ "public") do
    at =
      DateTime.utc_now() |> DateTime.add(-minutes_ago * 60, :second) |> DateTime.truncate(:second)

    Repo.insert!(%RemotePost{
      object_uri: "https://social.example/p/#{System.unique_integer([:positive])}",
      content_text: text,
      audience: audience,
      kind: "note",
      published_at: at,
      received_at: at,
      expires_at: DateTime.add(at, 30 * 86_400, :second),
      remote_account_id: account.id
    })
  end

  defp texts(user, n \\ 20) do
    user |> Fediverse.feed_remote_posts(n, nil) |> Enum.map(& &1.remote_post.content_text)
  end

  describe "several followed accounts at once" do
    test "the source merges them by publication time, not account by account" do
      user = member()
      a = account("alpha")
      b = account("beta")
      follow(user, a)
      follow(user, b)

      post(a, "alpha oldest", 30)
      post(b, "beta middle", 20)
      post(a, "alpha newest", 10)

      assert texts(user) == ["alpha newest", "beta middle", "alpha oldest"]
    end

    test "a post appears once, however many accounts the viewer follows" do
      user = member()
      accounts = for h <- ~w(one two three four five), do: account(h)
      for acc <- accounts, do: follow(user, acc)
      for {acc, i} <- Enum.with_index(accounts), do: post(acc, "post #{i}", i)

      got = texts(user)
      assert length(got) == 5
      assert got == Enum.uniq(got)
    end

    test "the limit takes the newest across all of them" do
      user = member()
      a = account("alpha")
      b = account("beta")
      follow(user, a)
      follow(user, b)

      # Interleaved: alpha on the even minutes, beta on the odd ones, so the
      # true newest three alternate between the accounts. A per-account plan
      # that forgot to merge would hand back one account's three.
      for i <- 1..6, do: post(a, "alpha #{i}", 12 - 2 * i)
      for i <- 1..6, do: post(b, "beta #{i}", 13 - 2 * i)

      assert texts(user, 3) == ["alpha 6", "beta 6", "alpha 5"]
    end
  end

  describe "each account's follow state governs only that account" do
    test "a followers-only post shows for the accepted account and not the pending one" do
      user = member()
      yes = account("accepted")
      no = account("pending")
      follow(user, yes, "accepted")
      follow(user, no, "requested")

      post(yes, "private from accepted", 10, "followers")
      post(no, "private from pending", 9, "followers")
      post(no, "public from pending", 8, "public")

      got = texts(user)
      assert "private from accepted" in got
      assert "public from pending" in got
      refute "private from pending" in got
    end

    test "muting one account leaves the others alone" do
      user = member()
      loud = account("loud")
      quiet = account("quiet")
      follow(user, loud, "accepted", true)
      follow(user, quiet)

      post(loud, "from the muted one", 10)
      post(quiet, "from the other one", 9)

      assert texts(user) == ["from the other one"]
    end
  end

  describe "a viewer with no remote follows" do
    test "gets nothing, and asks the posts table nothing" do
      user = member()
      other = member()
      acc = account("somebody")
      follow(other, acc)
      post(acc, "not for you", 5)

      queries = count_queries(fn -> assert Fediverse.feed_remote_posts(user, 10, nil) == [] end)

      assert queries == 1,
             "following nobody out there should cost the follow lookup and no post query, got #{queries}"
    end
  end

  # Counts the SQL a block runs. Safe in an async module only because it asserts
  # a count for THIS process: the handler filters on self().
  defp count_queries(fun) do
    ref = make_ref()
    parent = self()
    handler = "rps-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:vutuv, :repo, :query],
      fn _e, _m, _md, _c -> if self() == parent, do: send(parent, {ref, :q}) end,
      nil
    )

    try do
      fun.()
      drain(ref, 0)
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(ref, n) do
    receive do
      {^ref, :q} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end
end
