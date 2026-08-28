defmodule Vutuv.FeedBandTest do
  @moduledoc """
  What the feed's filter band lists: who is in the account branch, in which
  order, and with which number beside them.

  The number is the one thing here that could silently mean something else, so
  it is asserted against posts written inside and outside the seven-day window
  rather than against a total. The order matters just as much: it decides which
  rows survive the cut, so a wrong sort does not merely reshuffle the list, it
  shows the wrong people.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.FeedBand
  alias Vutuv.Social.Follow

  defp remote_account(host, handle) do
    actor = "https://#{host}/users/#{handle}"

    Repo.insert!(%RemoteAccount{
      actor_uri: actor,
      host: host,
      handle: "@#{handle}@#{host}",
      name: handle,
      inbox_uri: actor <> "/inbox"
    })
  end

  defp remote_follow(viewer, account) do
    Repo.insert!(%Fediverse.Follow{
      user_id: viewer.id,
      remote_account_id: account.id,
      state: "accepted",
      muted: false,
      follow_activity_id: "https://vutuv.test/#{viewer.id}/actor#follows/#{account.id}"
    })
  end

  defp remote_post_for(account, ago_days) do
    at = DateTime.utc_now() |> DateTime.add(-ago_days, :day) |> DateTime.truncate(:second)

    Repo.insert!(%RemotePost{
      remote_account_id: account.id,
      object_uri: "#{account.actor_uri}/statuses/#{System.unique_integer([:positive])}",
      content_text: "hello",
      audience: "public",
      published_at: at,
      received_at: at,
      expires_at: DateTime.add(at, 90, :day)
    })
  end

  defp post_for(user, ago_days) do
    at =
      NaiveDateTime.utc_now(:second)
      |> NaiveDateTime.add(-ago_days, :day)

    insert(:post, user: user, inserted_at: at, updated_at: at)
  end

  defp follows(follower, followee, muted \\ false) do
    Repo.insert!(%Follow{follower_id: follower.id, followee_id: followee.id, muted: muted})
  end

  describe "the account branch" do
    setup do
      viewer = insert(:user)
      loud = insert(:user, first_name: "Loud", last_name: "One", username: "loud-one")
      quiet = insert(:user, first_name: "Quiet", last_name: "One", username: "quiet-one")
      silent = insert(:user, first_name: "Silent", last_name: "One", username: "silent-one")

      follows(viewer, loud)
      follows(viewer, quiet)
      follows(viewer, silent)

      for _ <- 1..3, do: post_for(loud, 1)
      post_for(quiet, 2)
      # Outside the window: it must not count towards either of them.
      post_for(quiet, FeedBand.window_days() + 3)
      post_for(silent, FeedBand.window_days() + 1)

      %{viewer: viewer, loud: loud, quiet: quiet, silent: silent}
    end

    test "counts only what was written inside the window", %{viewer: viewer} do
      by_name = Map.new(FeedBand.accounts(viewer), &{&1.name, &1.posts})

      assert by_name["Loud One"] == 3
      assert by_name["Quiet One"] == 1
      assert by_name["Silent One"] == 0
    end

    test "orders by traffic, and the sort decides who survives the cut", %{viewer: viewer} do
      assert [first, second | _] = FeedBand.accounts(viewer, sort: :active)
      assert first.name == "Loud One"
      assert second.name == "Quiet One"

      assert [%{name: "Loud One"}] = FeedBand.accounts(viewer, sort: :active, limit: 1)
    end

    test "orders alphabetically on request", %{viewer: viewer} do
      names = viewer |> FeedBand.accounts(sort: :name) |> Enum.map(& &1.name)

      assert names == Enum.sort(names)
    end

    test "orders by who posted last", %{viewer: viewer} do
      assert [%{name: "Loud One"} | rest] = FeedBand.accounts(viewer, sort: :recent)
      assert Enum.map(rest, & &1.name) |> Enum.take(1) == ["Quiet One"]
    end

    test "narrows by name and by handle", %{viewer: viewer} do
      assert [%{name: "Quiet One"}] = FeedBand.accounts(viewer, query: "quiet")
      assert [%{name: "Quiet One"}] = FeedBand.accounts(viewer, query: "quiet-one")
      assert FeedBand.accounts(viewer, query: "nobody") == []
    end

    test "a switched-off account stays listed past the cap, or it could never come back", %{
      viewer: viewer,
      silent: silent
    } do
      Repo.update_all(
        from(f in Follow, where: f.follower_id == ^viewer.id and f.followee_id == ^silent.id),
        set: [muted: true]
      )

      rows = FeedBand.accounts(viewer, limit: 1)

      assert Enum.find(rows, &(&1.name == "Silent One")).muted?
      assert Enum.any?(rows, &(&1.name == "Loud One"))
    end

    test "counts every follow, whatever its traffic", %{viewer: viewer} do
      assert FeedBand.account_count(viewer) == 3
    end
  end

  describe "pages" do
    test "a followed page is an account row like any other" do
      viewer = insert(:user)
      page = insert(:organization, name: "Bremen Marketing")
      Repo.insert!(%Follow{follower_id: viewer.id, followee_organization_id: page.id})

      assert [row] = FeedBand.accounts(viewer)
      assert row.kind == :page
      assert row.name == "Bremen Marketing"
      assert row.posts == 0
    end
  end

  describe "the server branch" do
    setup do
      viewer = insert(:user)
      loud = remote_account("loud.example", "loud")
      quiet = remote_account("quiet.example", "quiet")

      remote_follow(viewer, loud)
      remote_follow(viewer, quiet)

      for _ <- 1..3, do: remote_post_for(loud, 1)
      remote_post_for(quiet, 1)
      remote_post_for(quiet, FeedBand.window_days() + 1)

      %{viewer: viewer, loud: loud, quiet: quiet}
    end

    test "groups accounts by host and counts the window", %{viewer: viewer} do
      by_host = Map.new(FeedBand.servers(viewer), &{&1.host, &1})

      assert by_host["loud.example"].posts == 3
      assert by_host["quiet.example"].posts == 1
      # The row wears the short handle: the host is already the branch it sits under.
      assert [%{handle: "@loud", name: "loud"}] = by_host["loud.example"].accounts
    end
  end
end
