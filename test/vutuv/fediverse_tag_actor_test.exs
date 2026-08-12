defmodule Vutuv.FediverseTagActorTest do
  @moduledoc """
  The keypair behind a tag's future `Group` actor (issue #1330).

  Only the keypair: what a remote server can see has to arrive together with an
  inbox that answers `Follow`, or somebody presses Follow on Mastodon and it
  stays pending forever. A keypair is invisible outside this database, which is
  exactly why the page half of #1334 shipped its own the same way.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Actor
  alias Vutuv.Tags.Tag

  defp tag(prefix \\ "topic") do
    n = System.unique_integer([:positive])
    insert(:tag, name: "#{prefix}#{n}", slug: "#{prefix}#{n}")
  end

  test "a tag gets a keypair on first use and keeps it" do
    tag = tag()

    assert {:ok, %Actor{} = actor} = Fediverse.ensure_tag_actor(tag)
    assert actor.tag_id == tag.id
    assert actor.private_key_pem =~ "PRIVATE KEY"
    assert actor.public_key_pem =~ "PUBLIC KEY"

    # Idempotent: a second call must not mint a second identity for one topic.
    assert {:ok, %Actor{id: same}} = Fediverse.ensure_tag_actor(tag)
    assert same == actor.id
  end

  test "an alias is another name for a topic, not a second address for it" do
    topic = tag("canonical")
    n = System.unique_integer([:positive])

    other_name =
      insert(:tag, name: "alias#{n}", slug: "alias#{n}", merged_into_id: topic.id)

    assert {:error, :alias} = Fediverse.ensure_tag_actor(other_name)
    refute Fediverse.get_tag_actor(other_name)
  end

  test "the owner column is exactly one of three" do
    tag = tag()
    user = insert(:activated_user)

    # The CHECK the migration widened: a row naming two owners is a second
    # identity for one thing, and the pair-shaped bugs of #1334 all began with a
    # column that could hold both.
    error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Actor{
          tag_id: tag.id,
          user_id: user.id,
          private_key_pem: "x",
          public_key_pem: "y"
        })
      end

    assert error.message =~ "fediverse_actors_exactly_one_owner"
  end

  test "deleting the tag takes its keypair with it" do
    tag = tag()
    {:ok, _} = Fediverse.ensure_tag_actor(tag)

    Repo.delete!(Repo.get!(Tag, tag.id))

    refute Repo.get_by(Actor, tag_id: tag.id)
  end
end
