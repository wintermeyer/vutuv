defmodule Vutuv.TagFollowSourcesTest do
  @moduledoc """
  A followed tag remembers **where** its posts should come from (issue #2125):
  one row per source, `vutuv` for this installation plus any server the member
  picked. `Vutuv.Tags.TagFollowSource` says why that is a table.

  Nothing user-facing stands on this yet; the tag card and the fetcher
  (#2126–#2129) do.
  """
  use Vutuv.DataCase, async: true

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

    test "our own address is the local source, not a server to fetch from" do
      follow = member_follow(insert(:tag))

      for ours <- ["localhost", "www.localhost", "http://localhost:4001/tags/elixir"] do
        assert {:ok, %TagFollowSource{source: "vutuv"}} = Tags.add_tag_follow_source(follow, ours)
      end

      assert Tags.tag_follow_sources(follow) == ["vutuv"]
    end

    test "refuses what is not a server name" do
      follow = member_follow(insert(:tag))

      for junk <- ["not a server", "", "mastodon"] do
        assert {:error, %Ecto.Changeset{} = changeset} = Tags.add_tag_follow_source(follow, junk)
        assert errors_on(changeset).source != []
      end

      assert Tags.tag_follow_sources(follow) == ["vutuv"]
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

    test "a follow with no sources is possible and simply wants nothing" do
      follow = insert(:tag_follow, user: insert(:user), tag: insert(:tag))

      assert %TagFollow{} = follow
      assert Tags.tag_follow_sources(follow) == []
    end
  end
end
