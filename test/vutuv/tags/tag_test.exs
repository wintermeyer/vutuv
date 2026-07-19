defmodule Vutuv.Tags.TagTest do
  use Vutuv.DataCase, async: true
  alias Vutuv.Tags.Tag

  describe "changeset/2 normalizes the value" do
    import Ecto.Changeset

    test "strips a leading # so the hashtag form stores the bare name" do
      changeset = Tag.changeset(%Tag{}, %{"value" => "#Elixir"})
      assert get_change(changeset, :name) == "Elixir"
      assert get_change(changeset, :slug) == "elixir"
    end

    test "keeps a trailing # (C# stays C#)" do
      changeset = Tag.changeset(%Tag{}, %{"value" => "C#"})
      assert get_change(changeset, :name) == "C#"
    end

    test "keeps a multi-word name and slugifies it" do
      changeset = Tag.changeset(%Tag{}, %{"value" => "Ruby on Rails"})
      assert get_change(changeset, :name) == "Ruby on Rails"
      assert get_change(changeset, :slug) == "ruby-on-rails"
    end

    test "collapses internal whitespace runs to a single space" do
      changeset = Tag.changeset(%Tag{}, %{"value" => "Ruby   on  Rails"})
      assert get_change(changeset, :name) == "Ruby on Rails"
    end
  end

  describe "related_users/2" do
    test "returns the current user's connections that are endorsed for the tag" do
      # Activated: the tag-page user queries hide unactivated accounts.
      viewer = insert(:user, email_confirmed?: true)
      a_follower = insert(:user, email_confirmed?: true)
      a_followee = insert(:user, email_confirmed?: true)

      # a_follower -> viewer (so a_follower is in viewer.followers)
      insert(:follow, follower: a_follower, followee: viewer)
      # viewer -> a_followee (so a_followee is in viewer.followees)
      insert(:follow, follower: viewer, followee: a_followee)

      tag = insert(:tag)

      for u <- [a_follower, a_followee] do
        user_tag = insert(:user_tag, user: u, tag: tag)
        insert(:user_tag_endorsement, user_tag: user_tag, user: insert(:user))
      end

      # Regression: on Postgres this raised 42P10 (SELECT DISTINCT + ORDER BY
      # count(...)) because followers/followees are has_many :through.
      ids = tag |> Tag.related_users(viewer) |> Enum.map(& &1.id) |> Enum.sort()

      assert ids == Enum.sort([a_follower.id, a_followee.id])
    end

    test "returns [] for an anonymous (nil) current user" do
      assert Tag.related_users(insert(:tag), nil) == []
    end
  end
end
