defmodule Vutuv.TagsTest do
  use Vutuv.DataCase

  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag

  describe "tags" do
    test "create_tag/1 stores the typed name and a generated slug" do
      assert {:ok, tag} = Tags.create_tag(%{"value" => "Elixir"})
      assert tag.name == "Elixir"
      assert tag.slug =~ "elixir"
    end

    test "get_tag_by_slug/1 returns a tag" do
      tag = insert(:tag, slug: "elixir")
      assert Tags.get_tag_by_slug("elixir").id == tag.id
    end

    test "get_tag_by_slug/1 returns nil for non-existent slug" do
      assert Tags.get_tag_by_slug("nonexistent") == nil
    end

    test "update_tag/2 updates a tag's name and slug" do
      tag = insert(:tag, name: "Old", slug: "old-slug")
      assert {:ok, updated} = Tags.update_tag(tag, %{name: "New", slug: "new-slug"})
      assert updated.name == "New"
      assert updated.slug == "new-slug"
    end
  end

  describe "create_or_link_tag/2" do
    import Ecto.Changeset

    defp link(value) do
      %UserTag{}
      |> change(%{})
      |> Tag.create_or_link_tag(%{"value" => value})
    end

    test "links to an existing tag whose name matches case-insensitively" do
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      changeset = link("elixir")
      assert get_change(changeset, :tag_id) == tag.id
    end

    test "builds a new tag when no name or slug matches" do
      changeset = link("Rust")
      refute get_change(changeset, :tag_id)
      built = get_change(changeset, :tag)
      assert get_change(built, :name) == "Rust"
      assert get_change(built, :slug) =~ "rust"
    end
  end

  describe "user_tags" do
    test "create_user_tag/1 creates a user tag" do
      user = insert(:user)
      tag = insert(:tag)
      assert {:ok, user_tag} = Tags.create_user_tag(%{user_id: user.id, tag_id: tag.id})
      assert user_tag.user_id == user.id
      assert user_tag.tag_id == tag.id
    end

    test "create_user_tag/1 prevents duplicate user-tag" do
      user = insert(:user)
      tag = insert(:tag)
      assert {:ok, _} = Tags.create_user_tag(%{user_id: user.id, tag_id: tag.id})
      assert {:error, _changeset} = Tags.create_user_tag(%{user_id: user.id, tag_id: tag.id})
    end

    test "list_user_tags/1 returns user's tags" do
      user = insert(:user)
      tag = insert(:tag)
      insert(:user_tag, user: user, tag: tag)
      assert length(Tags.list_user_tags(user)) == 1
    end

    test "UserTag.name/1 returns the tag's name" do
      user = insert(:user)
      tag = insert(:tag, name: "Elixir")
      user_tag = insert(:user_tag, user: user, tag: tag)
      assert UserTag.name(user_tag) == "Elixir"
    end
  end

  describe "user_tag_endorsements" do
    test "create_endorsement/1 creates an endorsement" do
      user = insert(:user)
      tag_owner = insert(:user)
      tag = insert(:tag)
      user_tag = insert(:user_tag, user: tag_owner, tag: tag)

      assert {:ok, endorsement} =
               Tags.create_endorsement(%{user_id: user.id, user_tag_id: user_tag.id})

      assert endorsement.user_id == user.id
      assert endorsement.user_tag_id == user_tag.id
    end

    test "tag_endorsed?/2 returns true when endorsed" do
      user = insert(:user)
      tag_owner = insert(:user)
      tag = insert(:tag)
      user_tag = insert(:user_tag, user: tag_owner, tag: tag)
      insert(:user_tag_endorsement, user: user, user_tag: user_tag)

      assert Tags.tag_endorsed?(user_tag.id, user.id)
    end

    test "tag_endorsed?/2 returns false when not endorsed" do
      user = insert(:user)
      tag_owner = insert(:user)
      tag = insert(:tag)
      user_tag = insert(:user_tag, user: tag_owner, tag: tag)

      refute Tags.tag_endorsed?(user_tag.id, user.id)
    end

    test "endorsement_count/1 returns the count" do
      tag_owner = insert(:user)
      tag = insert(:tag)
      user_tag = insert(:user_tag, user: tag_owner, tag: tag)

      user1 = insert(:user)
      user2 = insert(:user)
      insert(:user_tag_endorsement, user: user1, user_tag: user_tag)
      insert(:user_tag_endorsement, user: user2, user_tag: user_tag)

      assert Tags.endorsement_count(user_tag.id) == 2
    end
  end
end
