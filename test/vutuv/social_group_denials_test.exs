defmodule Vutuv.SocialGroupDenialsTest do
  @moduledoc """
  Deleting a group that posts deny must fail (RESTRICT): silently dropping
  the denial would widen the audience of old posts.
  """
  use Vutuv.DataCase

  alias Vutuv.Posts
  alias Vutuv.Social

  test "delete_group/1 refuses while posts deny the group, succeeds after" do
    user = insert(:user, activated?: true)
    group = insert(:group, user: user)

    {:ok, post} = Posts.create_post(user, %{body: "x", denials: [%{"group_id" => group.id}]})

    assert {:error, changeset} = Social.delete_group(group)
    assert %{id: [_message]} = errors_on(changeset)
    assert Repo.get(Social.Group, group.id)

    # Widening the post's audience explicitly frees the group.
    {:ok, _} = Posts.update_post(post, %{body: "x", denials: []})
    assert {:ok, _} = Social.delete_group(group)
  end

  test "groups_with_member_counts/1 counts live membership" do
    user = insert(:user)
    group = insert(:group, user: user, name: "Circle")
    connection = insert(:connection, follower: user, followee: insert(:user))
    insert(:membership, connection: connection, group: group)
    insert(:group, user: user, name: "Empty")

    assert [{%{name: "Circle"}, 1}, {%{name: "Empty"}, 0}] =
             Social.groups_with_member_counts(user)
  end
end
