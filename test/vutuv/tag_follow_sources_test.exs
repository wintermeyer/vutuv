defmodule Vutuv.TagFollowSourcesTest do
  @moduledoc """
  A followed tag remembers **where** its posts should come from (issue #2125):
  one row per source, `vutuv` for this installation plus any server the member
  picked. `Vutuv.Tags.TagFollowSource` says why that is a table.

  Nothing user-facing stands on this yet; the tag card and the fetcher
  (#2126–#2129) do.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Fediverse
  alias Vutuv.Tags
  alias Vutuv.Tags.TagFollow
  alias Vutuv.Tags.TagFollowSource

  defp member_follow(tag) do
    {:ok, follow} = Tags.follow_tag(insert(:user), tag)
    follow
  end

  describe "the local source comes with the follow" do
    test "a member's new follow is a vutuv source and nothing else" do
      follow = member_follow(insert(:tag))

      assert Tags.tag_follow_sources(follow) == ["vutuv"]
      assert Tags.local_tag_follow_source() == "vutuv"
    end

    test "a page's new follow gets the same one" do
      page = insert(:organization)

      assert {:ok, follow} = Tags.follow_tag_as_organization(page, insert(:tag))
      assert Tags.tag_follow_sources(follow) == ["vutuv"]
    end

    test "following twice keeps exactly one local source row" do
      user = insert(:user)
      tag = insert(:tag)

      assert {:ok, _} = Tags.follow_tag(user, tag)
      assert {:ok, follow} = Tags.follow_tag(user, tag)

      assert Tags.tag_follow_sources(follow) == ["vutuv"]
      assert Repo.aggregate(TagFollowSource, :count) == 1
    end

    test "unfollowing takes the sources with it" do
      user = insert(:user)
      tag = insert(:tag)
      {:ok, follow} = Tags.follow_tag(user, tag)
      {:ok, _} = Tags.add_tag_follow_source(follow, "mastodon.social")

      assert Tags.unfollow_tag(user, tag) == 1
      assert Repo.aggregate(TagFollowSource, :count) == 0
    end
  end

  describe "add_tag_follow_source/2" do
    test "adds a server after the local source, idempotently" do
      follow = member_follow(insert(:tag))

      assert {:ok, %TagFollowSource{}} = Tags.add_tag_follow_source(follow, "mastodon.social")
      assert {:ok, %TagFollowSource{}} = Tags.add_tag_follow_source(follow, "mastodon.social")

      assert Tags.tag_follow_sources(follow) == ["vutuv", "mastodon.social"]
    end

    test "takes whatever the member pasted and keeps the hostname" do
      follow = member_follow(insert(:tag))

      assert {:ok, _} = Tags.add_tag_follow_source(follow, "https://Mastodon.Social/tags/elixir")
      assert {:ok, _} = Tags.add_tag_follow_source(follow, "  @bob@Troet.Cafe ")

      assert Tags.tag_follow_sources(follow) == ["vutuv", "mastodon.social", "troet.cafe"]
    end

    test "folds www. away, so one server is one row" do
      follow = member_follow(insert(:tag))

      assert {:ok, %TagFollowSource{source: "mastodon.social"}} =
               Tags.add_tag_follow_source(follow, "www.mastodon.social")

      assert {:ok, _} = Tags.add_tag_follow_source(follow, "mastodon.social")
      assert Tags.tag_follow_sources(follow) == ["vutuv", "mastodon.social"]
    end

    # Folding one label let the fold itself be walked around: `www.www.host`
    # came out as `www.host`, which is a subdomain somebody other than the
    # author may hold, and this is the host we then poll and store rows from
    # (PR #2176). Every leading `www.` goes, so no source can carry one.
    test "folds every leading www., so the fold cannot be walked around" do
      follow = member_follow(insert(:tag))

      assert {:ok, %TagFollowSource{source: "mastodon.social"}} =
               Tags.add_tag_follow_source(follow, "www.www.mastodon.social")

      assert Tags.tag_follow_sources(follow) == ["vutuv", "mastodon.social"]
    end

    test "every spelling of this installation's own address is the local source" do
      follow = member_follow(insert(:tag))
      # Taken from the endpoint, not written out: the rule under test is
      # `Fediverse.own_host?/1`, and hardcoding the test host ("localhost")
      # would pass on a fixture rather than on the rule. The tag host is here
      # because it is us too, and it is the spelling a hardcoded test misses.
      host = VutuvWeb.Endpoint.host()

      for ours <- [
            host,
            "www." <> host,
            "www.www." <> host,
            "https://#{host}/tags/elixir",
            Fediverse.tag_host()
          ] do
        assert {:ok, %TagFollowSource{source: "vutuv"}} = Tags.add_tag_follow_source(follow, ours)
      end

      assert Tags.tag_follow_sources(follow) == ["vutuv"]
    end

    test "refuses what is not a server name" do
      follow = member_follow(insert(:tag))

      for junk <- ["not a server", "", "mastodon", "[::1]"] do
        assert {:error, %Ecto.Changeset{} = changeset} = Tags.add_tag_follow_source(follow, junk)
        assert errors_on(changeset).source != []
      end

      assert Tags.tag_follow_sources(follow) == ["vutuv"]
    end

    test "refuses an address inside our own network — the fetcher would go there" do
      follow = member_follow(insert(:tag))

      # A source is a host #2126 will fetch from, so this is a stored SSRF
      # target. The server-name grammar alone accepts every one of these, which
      # is why the error asserted here is the SSRF layer's own and not "is not
      # a server name".
      for internal <- ["169.254.169.254", "127.0.0.1", "10.0.0.5", "192.168.1.1"] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Tags.add_tag_follow_source(follow, internal)

        assert "is not an allowed server" in errors_on(changeset).source
      end

      assert Tags.tag_follow_sources(follow) == ["vutuv"]
      assert Tags.wanted_tag_sources() == []
    end

    test "refuses a hostname longer than its column" do
      follow = member_follow(insert(:tag))
      long = String.duplicate("a", 250) <> ".example"

      assert {:error, changeset} = Tags.add_tag_follow_source(follow, long)
      assert errors_on(changeset).source != []
    end
  end

  describe "remove_tag_follow_source/2" do
    test "removes one named source and is idempotent" do
      follow = member_follow(insert(:tag))
      {:ok, _} = Tags.add_tag_follow_source(follow, "mastodon.social")

      assert Tags.remove_tag_follow_source(follow, "mastodon.social") == 1
      assert Tags.remove_tag_follow_source(follow, "mastodon.social") == 0
      assert Tags.tag_follow_sources(follow) == ["vutuv"]
    end

    test "reads a pasted address the same way adding did" do
      follow = member_follow(insert(:tag))
      {:ok, _} = Tags.add_tag_follow_source(follow, "mastodon.social")

      assert Tags.remove_tag_follow_source(follow, "https://Mastodon.Social/") == 1
      assert Tags.tag_follow_sources(follow) == ["vutuv"]
    end

    test "leaves another follow's source alone" do
      tag = insert(:tag)
      mine = member_follow(tag)
      theirs = member_follow(tag)
      {:ok, _} = Tags.add_tag_follow_source(mine, "mastodon.social")
      {:ok, _} = Tags.add_tag_follow_source(theirs, "mastodon.social")

      assert Tags.remove_tag_follow_source(mine, "mastodon.social") == 1
      assert Tags.tag_follow_sources(theirs) == ["vutuv", "mastodon.social"]
    end
  end

  describe "wanted_tag_sources/0" do
    test "answers one row per server-and-tag pair, with how many want it" do
      tag = insert(:tag, name: "Elixir")
      other = insert(:tag, name: "Bahn")
      page = insert(:organization)
      {:ok, page_follow} = Tags.follow_tag_as_organization(page, tag)

      for follow <- [member_follow(tag), member_follow(tag), page_follow] do
        {:ok, _} = Tags.add_tag_follow_source(follow, "mastodon.social")
      end

      {:ok, _} = Tags.add_tag_follow_source(member_follow(other), "troet.cafe")

      assert [bahn, elixir] = Enum.sort_by(Tags.wanted_tag_sources(), & &1.tag_name)

      assert bahn == %{
               source: "troet.cafe",
               tag_id: other.id,
               tag_name: "Bahn",
               follow_count: 1
             }

      assert elixir == %{
               source: "mastodon.social",
               tag_id: tag.id,
               tag_name: "Elixir",
               follow_count: 3
             }
    end

    test "never asks this installation for its own posts" do
      member_follow(insert(:tag))

      assert Tags.wanted_tag_sources() == []
    end

    test "forgets a pair once the last follower drops it" do
      follow = member_follow(insert(:tag))
      {:ok, _} = Tags.add_tag_follow_source(follow, "mastodon.social")
      assert Tags.remove_tag_follow_source(follow, "mastodon.social") == 1

      assert Tags.wanted_tag_sources() == []
    end
  end

  describe "the row itself" do
    test "the database refuses the same source twice on one follow" do
      follow = member_follow(insert(:tag))

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%TagFollowSource{tag_follow_id: follow.id, source: "vutuv"})
      end
    end

    test "a follow written with no sources at all still reads as vutuv" do
      # What the previous release keeps writing during a blue/green deploy: it
      # knows nothing about this table, and nothing backfills those rows
      # afterwards. vutuv is always on (#2128), so this is the same answer.
      follow = insert(:tag_follow, user: insert(:user), tag: insert(:tag))

      assert %TagFollow{} = follow
      assert Tags.tag_follow_sources(follow) == ["vutuv"]

      # And still after it gains its first server: an "empty means vutuv" rule
      # would stop firing right here and switch this installation off for a
      # follow whose owner never asked for that.
      {:ok, _} = Tags.add_tag_follow_source(follow, "mastodon.social")
      assert Tags.tag_follow_sources(follow) == ["vutuv", "mastodon.social"]
    end

    test "a preloaded follow answers the same, without a second query" do
      follow = member_follow(insert(:tag))
      {:ok, _} = Tags.add_tag_follow_source(follow, "mastodon.social")
      bare = insert(:tag_follow, user: insert(:user), tag: insert(:tag))

      preloaded = Repo.preload([follow, bare], :sources)

      assert Enum.map(preloaded, &Tags.tag_follow_sources/1) == [
               ["vutuv", "mastodon.social"],
               ["vutuv"]
             ]
    end

    test "the local source cannot be switched off" do
      follow = member_follow(insert(:tag))
      {:ok, _} = Tags.add_tag_follow_source(follow, "mastodon.social")

      assert Tags.remove_tag_follow_source(follow, "vutuv") == 0
      assert Tags.remove_tag_follow_source(follow, VutuvWeb.Endpoint.host()) == 0
      assert Tags.tag_follow_sources(follow) == ["vutuv", "mastodon.social"]
    end
  end
end
