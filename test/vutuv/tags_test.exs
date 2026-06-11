defmodule Vutuv.TagsTest do
  use Vutuv.DataCase

  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag

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

    test "a new tag keeps the entered casing as its display name" do
      # "UX" must not become the chip "ux" - only the slug is lowercased.
      # (Lowercase chips on old profiles come from 2017 legacy tag names,
      # not from this path.)
      user = insert(:user)
      {:ok, user_tag} = Tags.add_user_tag(user, "WebAssembly")

      tag = Repo.preload(user_tag, :tag).tag
      assert tag.name == "WebAssembly"
      assert tag.slug == "webassembly"
    end
  end

  describe "user_tags" do
    test "UserTag.name/1 returns the tag's name" do
      user = insert(:user)
      tag = insert(:tag, name: "Elixir")
      user_tag = insert(:user_tag, user: user, tag: tag)
      assert UserTag.name(user_tag) == "Elixir"
    end
  end

  describe "recommended_users/1" do
    test "hides unactivated and moderation-hidden accounts" do
      # Same visibility gate as search and the most-followed listing: a frozen
      # or never-activated account must not surface on the public tag page.
      tag = insert(:tag)
      visible = insert(:user, activated?: true)
      unactivated = insert(:user)
      frozen = insert(:user, activated?: true, frozen_at: ~N[2026-01-01 00:00:00])

      for owner <- [visible, unactivated, frozen] do
        insert(:user_tag, user: owner, tag: tag)
      end

      ids = Tag.recommended_users(tag) |> Enum.map(& &1.id)

      assert visible.id in ids
      refute unactivated.id in ids
      refute frozen.id in ids
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

    test "create_endorsement/1 pushes a live notification to the tag's owner" do
      endorser = insert(:user, first_name: "Ada", last_name: "Lovelace")
      tag_owner = insert(:user)
      tag = insert(:tag, name: "Phoenix")
      user_tag = insert(:user_tag, user: tag_owner, tag: tag)

      Vutuv.Activity.subscribe(tag_owner.id)

      assert {:ok, _} = Tags.create_endorsement(%{user_id: endorser.id, user_tag_id: user_tag.id})

      assert_receive {:new_notification,
                      %{kind: "endorsement", tag: "Phoenix", actor_name: "Ada Lovelace"} = n}

      assert n.actor_param == endorser.active_slug
    end

    test "create_endorsement/1 does not notify on a self-endorsement" do
      tag_owner = insert(:user)
      tag = insert(:tag)
      user_tag = insert(:user_tag, user: tag_owner, tag: tag)

      Vutuv.Activity.subscribe(tag_owner.id)

      assert {:ok, _} =
               Tags.create_endorsement(%{user_id: tag_owner.id, user_tag_id: user_tag.id})

      refute_receive {:new_notification, _}
    end
  end
end
