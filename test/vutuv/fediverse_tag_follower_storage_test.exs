defmodule Vutuv.FediverseTagFollowerStorageTest do
  @moduledoc """
  Where a remote follower of a **topic** is recorded (issue #1330).

  Storage only, like the keypair before it: nothing writes these yet and nothing
  outside this database can see one. What a remote server *can* see — WebFinger
  on the tag host, the `Group` document, the inbox that answers `Follow` — still
  has to arrive together, because a recorded Follow that is never answered shows
  as pending forever on the other side.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Fediverse.Follower
  alias Vutuv.Tags.Tag

  defp tag do
    n = System.unique_integer([:positive])
    insert(:tag, name: "topic#{n}", slug: "topic#{n}")
  end

  defp follower(attrs) do
    Repo.insert(
      struct(
        %Follower{
          actor_uri: "https://remote.example/users/frida",
          inbox_uri: "https://remote.example/users/frida/inbox"
        },
        attrs
      )
    )
  end

  test "a topic can hold remote followers" do
    tag = tag()

    assert {:ok, row} = follower(tag_id: tag.id)
    assert row.tag_id == tag.id
    assert is_nil(row.user_id)
    assert is_nil(row.organization_id)
  end

  test "one remote account follows one topic once" do
    tag = tag()
    assert {:ok, _} = follower(tag_id: tag.id)

    # What makes re-delivering a `Follow` idempotent rather than a second row.
    assert_raise Ecto.ConstraintError, ~r/fediverse_followers_tag_id_actor_uri_index/, fn ->
      follower(tag_id: tag.id)
    end
  end

  test "the same account may follow a topic and a member separately" do
    tag = tag()
    user = insert(:activated_user)

    assert {:ok, _} = follower(tag_id: tag.id)
    assert {:ok, _} = follower(user_id: user.id)
  end

  test "a row names exactly one owner" do
    tag = tag()
    user = insert(:activated_user)

    error =
      assert_raise Ecto.ConstraintError, fn ->
        follower(tag_id: tag.id, user_id: user.id)
      end

    assert error.message =~ "fediverse_followers_exactly_one_target"
  end

  test "deleting the topic takes its followers with it" do
    tag = tag()
    {:ok, row} = follower(tag_id: tag.id)

    Repo.delete!(Repo.get!(Tag, tag.id))

    refute Repo.get(Follower, row.id)
  end
end
