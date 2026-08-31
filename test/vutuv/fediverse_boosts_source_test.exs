defmodule Vutuv.FediverseBoostsSourceTest do
  @moduledoc """
  The feed's boost source across **several** boosting accounts at once.

  It used to reach them through a join to `fediverse_follows`, which kept
  Postgres off `fediverse_post_boosts_recency_index` for anything but the
  smallest page: measured on the production copy (2026-08-31) it took the index
  at limit 11 and fell back to a full scan the moment the page grew — 3,039
  buffers at the fill's limit of 31, 3,708 at a calendar day's 100. The boosters
  are now read first and handed over as a constant id list, so it walks the
  index at every limit (156 and 448 buffers).

  `fediverse_post_boosts_test.exs` pins what one booster may show whom. What is
  new here is what the join did implicitly across **many**: no duplicates, one
  merged order, and each follow's own state and mute honoured.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.PostBoost
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Posts

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
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/#{account.id}"
    })
  end

  # A vutuv member's post passed on by a remote account — the `post_id` half of
  # a boost, which needs no third server to resolve.
  defp boost(account, post, minutes_ago) do
    Repo.insert!(%PostBoost{
      remote_account_id: account.id,
      post_id: post.id,
      activity_id: "https://social.example/act/#{System.unique_integer([:positive])}",
      announced_at: DateTime.utc_now(:second) |> DateTime.add(-minutes_ago * 60, :second)
    })
  end

  defp author_post(body) do
    author = insert(:activated_user, fediverse_followers?: true)
    {:ok, _} = Fediverse.ensure_actor(author)
    Vutuv.PostsHelpers.create_post!(Repo.reload!(author), %{body: body})
  end

  defp boosted_bodies(user) do
    user
    |> Posts.feed_page(limit: 20)
    |> Map.fetch!(:entries)
    |> Enum.filter(&(&1[:boosted_by] != nil))
    |> Enum.map(& &1.post.body)
  end

  describe "several boosting accounts at once" do
    test "the source merges them by announce time, not account by account" do
      user = member()
      a = account("alpha")
      b = account("beta")
      follow(user, a)
      follow(user, b)

      boost(a, author_post("oldest"), 30)
      boost(b, author_post("middle"), 20)
      boost(a, author_post("newest"), 10)

      assert boosted_bodies(user) == ["newest", "middle", "oldest"]
    end

    test "a boost appears once, however many accounts the viewer follows" do
      user = member()
      accounts = for h <- ~w(one two three four), do: account(h)
      for acc <- accounts, do: follow(user, acc)
      for {acc, i} <- Enum.with_index(accounts), do: boost(acc, author_post("post #{i}"), i)

      got = boosted_bodies(user)
      assert length(got) == 4
      assert got == Enum.uniq(got)
    end
  end

  describe "each follow's own state governs its boosts" do
    test "only an accepted follow carries them" do
      user = member()
      yes = account("accepted")
      no = account("pending")
      follow(user, yes, "accepted")
      follow(user, no, "requested")

      boost(yes, author_post("from the accepted one"), 10)
      boost(no, author_post("from the pending one"), 9)

      assert boosted_bodies(user) == ["from the accepted one"]
    end

    test "muting one booster leaves the others alone" do
      user = member()
      loud = account("loud")
      quiet = account("quiet")
      follow(user, loud, "accepted", true)
      follow(user, quiet)

      boost(loud, author_post("from the muted one"), 10)
      boost(quiet, author_post("from the other one"), 9)

      assert boosted_bodies(user) == ["from the other one"]
    end

    test "somebody else's follow carries nothing to this reader" do
      user = member()
      stranger = member()
      acc = account("theirs")
      follow(stranger, acc)

      boost(acc, author_post("not for you"), 5)

      assert boosted_bodies(user) == []
    end
  end
end
