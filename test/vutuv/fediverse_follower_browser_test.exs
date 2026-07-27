defmodule Vutuv.FediverseFollowerBrowserTest do
  @moduledoc """
  The query layer behind the member's follower browser
  (/settings/fediverse/followers): a flat list stops working long before a
  popular account's follower count does, so the owner's list is searched,
  filtered by server, sorted and paginated in SQL.

  Rows are inserted straight through the Repo rather than through
  `add_follower/2`, which is rate limited on shared (not rolled back) state -
  these tests are about the reading side.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follower

  defp follower(user, attrs) do
    host = attrs[:host] || "mastodon.example"
    handle = attrs[:handle] || "someone"

    Repo.insert!(%Follower{
      user_id: user.id,
      actor_uri: "https://#{host}/users/#{handle}",
      inbox_uri: "https://#{host}/users/#{handle}/inbox",
      handle: handle,
      name: attrs[:name]
    })
  end

  describe "browse_filters/1" do
    test "falls back to safe defaults and rejects unknown values" do
      assert %{q: nil, server: nil, sort: "followed", dir: "desc"} =
               Fediverse.browse_filters(%{})

      assert %{sort: "followed", dir: "desc"} =
               Fediverse.browse_filters(%{"sort" => "; drop table", "dir" => "sideways"})

      assert %{q: nil, server: nil} = Fediverse.browse_filters(%{"q" => "  ", "server" => ""})
    end

    test "a text column defaults to A-Z, the date column to newest first" do
      assert %{sort: "account", dir: "asc"} = Fediverse.browse_filters(%{"sort" => "account"})
      assert %{sort: "server", dir: "asc"} = Fediverse.browse_filters(%{"sort" => "server"})

      assert %{sort: "followed", dir: "desc"} =
               Fediverse.browse_filters(%{"sort" => "followed"})

      assert %{sort: "account", dir: "desc"} =
               Fediverse.browse_filters(%{"sort" => "account", "dir" => "desc"})
    end

    test "a server filter is matched case-insensitively" do
      assert %{server: "mastodon.social"} =
               Fediverse.browse_filters(%{"server" => "Mastodon.Social"})
    end
  end

  describe "searching" do
    setup do
      user = insert(:activated_user, fediverse_followers?: true)

      follower(user, handle: "crse", name: "Christian Yoga", host: "social.linux.pizza")
      follower(user, handle: "jti42", name: "JTI", host: "infosec.exchange")
      follower(user, handle: "116862070468658358", name: nil, host: "mastodon.social")

      %{user: user}
    end

    test "matches the display name, the handle and the server", %{user: user} do
      assert ["crse"] = handles(user, %{"q" => "christian"})
      assert ["jti42"] = handles(user, %{"q" => "JTI4"})
      assert ["crse"] = handles(user, %{"q" => "linux.pizza"})
    end

    test "a pasted @user@host handle finds exactly that account", %{user: user} do
      assert ["crse"] = handles(user, %{"q" => "@crse@social.linux.pizza"})
      assert ["crse"] = handles(user, %{"q" => "crse@social.linux.pizza"})
      # The two halves must both match: right name, wrong server finds nothing.
      assert [] = handles(user, %{"q" => "@crse@infosec.exchange"})
    end

    test "a leading @ on a bare handle is ignored", %{user: user} do
      assert ["jti42"] = handles(user, %{"q" => "@jti42"})
    end

    test "LIKE wildcards in the search term are literal, not patterns", %{user: user} do
      assert [] = handles(user, %{"q" => "%"})
    end
  end

  describe "filtering by server" do
    setup do
      user = insert(:activated_user, fediverse_followers?: true)

      follower(user, handle: "a", host: "mastodon.social")
      follower(user, handle: "b", host: "mastodon.social")
      follower(user, handle: "c", host: "infosec.exchange")

      %{user: user}
    end

    test "narrows to one server and counts it", %{user: user} do
      filters = Fediverse.browse_filters(%{"server" => "mastodon.social"})

      assert Fediverse.count_followers(user, filters) == 2
      assert ["b", "a"] = Enum.map(Fediverse.list_followers_page(user, filters), & &1.handle)
    end

    test "follower_hosts/2 lists the member's servers, biggest first", %{user: user} do
      assert [
               %{host: "mastodon.social", count: 2},
               %{host: "infosec.exchange", count: 1}
             ] = Fediverse.follower_hosts(user)
    end

    test "one member's servers never leak into another's", %{user: user} do
      other = insert(:activated_user, fediverse_followers?: true)
      follower(other, handle: "z", host: "elsewhere.example")

      assert Enum.map(Fediverse.follower_hosts(user), & &1.host) == [
               "mastodon.social",
               "infosec.exchange"
             ]

      assert Fediverse.count_followers(user, %{}) == 3
      assert Fediverse.count_followers(other, %{}) == 1
    end
  end

  describe "sorting" do
    setup do
      user = insert(:activated_user, fediverse_followers?: true)

      # Inserted oldest first; ids are UUID v7, so id order is arrival order.
      follower(user, handle: "zoe", name: "Anna Zeta", host: "zulu.example")
      follower(user, handle: "abe", name: nil, host: "alpha.example")
      follower(user, handle: "mia", name: "mira", host: "mike.example")

      %{user: user}
    end

    test "by arrival, newest first by default", %{user: user} do
      assert ["mia", "abe", "zoe"] = sorted(user, %{})
      assert ["zoe", "abe", "mia"] = sorted(user, %{"sort" => "followed", "dir" => "asc"})
    end

    test "the arrival sort follows the inserted_at the column shows", %{user: user} do
      # Rows created in one test share an inserted_at second, so backdate them
      # apart — the order must follow those dates, not the insert order (the
      # two agree in production, and a browser check on backdated seed data is
      # what caught the column contradicting itself).
      %{"zoe" => ~N[2026-07-01 09:00:00], "abe" => ~N[2024-01-05 08:00:00]}
      |> Enum.each(fn {handle, stamp} ->
        Repo.get_by!(Follower, user_id: user.id, handle: handle)
        |> Ecto.Changeset.change(inserted_at: stamp)
        |> Repo.update!()
      end)

      newest_first = Fediverse.list_followers_page(user, Fediverse.browse_filters(%{}))

      # "mia" keeps today's stamp, so it leads although "zoe" was inserted first.
      assert Enum.map(newest_first, & &1.handle) == ["mia", "zoe", "abe"]

      assert newest_first
             |> Enum.map(& &1.inserted_at)
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> NaiveDateTime.compare(a, b) != :lt end)
    end

    test "by account label: the display name, else the handle, case-insensitively", %{user: user} do
      # "abe" has no name, so it sorts under its handle; "mira" is lowercase
      # and must still land between "Anna Zeta" and "abe".
      assert ["abe", "zoe", "mia"] = sorted(user, %{"sort" => "account"})
      assert ["mia", "zoe", "abe"] = sorted(user, %{"sort" => "account", "dir" => "desc"})
    end

    test "by server", %{user: user} do
      assert ["abe", "mia", "zoe"] = sorted(user, %{"sort" => "server"})
      assert ["zoe", "mia", "abe"] = sorted(user, %{"sort" => "server", "dir" => "desc"})
    end
  end

  describe "pagination" do
    test "pages through the list without repeating or dropping a row" do
      user = insert(:activated_user, fediverse_followers?: true)
      for n <- 1..12, do: follower(user, handle: "f#{100 + n}")

      filters = Fediverse.browse_filters(%{})
      assert Fediverse.count_followers(user, filters) == 12

      page = fn n ->
        user
        |> Fediverse.list_followers_page(filters, %{"page" => to_string(n)}, per_page: 5)
        |> Enum.map(& &1.handle)
      end

      assert length(page.(1)) == 5
      assert length(page.(2)) == 5
      assert length(page.(3)) == 2

      seen = page.(1) ++ page.(2) ++ page.(3)
      assert length(Enum.uniq(seen)) == 12
    end

    test "the total is honoured so the caller can skip the recount" do
      user = insert(:activated_user, fediverse_followers?: true)
      for n <- 1..4, do: follower(user, handle: "g#{n}")

      rows =
        Fediverse.list_followers_page(user, %{}, %{"page" => "2"}, per_page: 3, total: 4)

      assert length(rows) == 1
    end
  end

  test "Follower.host/1 is the Elixir twin of the SQL server column" do
    assert Follower.host(%Follower{actor_uri: "https://Mastodon.Social/users/x"}) ==
             "mastodon.social"

    assert Follower.host(%Follower{actor_uri: "https://social.example:8443/users/x"}) ==
             "social.example"
  end

  defp handles(user, params) do
    user
    |> Fediverse.list_followers_page(Fediverse.browse_filters(params))
    |> Enum.map(& &1.handle)
  end

  defp sorted(user, params), do: handles(user, params)
end
