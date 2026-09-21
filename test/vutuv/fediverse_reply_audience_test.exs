defmodule Vutuv.FediverseReplyAudienceTest do
  @moduledoc """
  Who receives a member's answer to another vutuv post: the servers following
  the member who answered, and the servers following the member they answered
  (`Vutuv.Fediverse.recipients/2` says why).
  """
  use Vutuv.DataCase, async: true

  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Posts
  alias Vutuv.Posts.PostDenial

  defp remote_follower(user, host) do
    actor = "https://#{host}/users/#{System.unique_integer([:positive])}"

    {:ok, _} =
      Fediverse.add_follower(user, %{
        actor_uri: actor,
        inbox_uri: actor <> "/inbox",
        shared_inbox_uri: "https://#{host}/inbox"
      })

    "https://#{host}/inbox"
  end

  defp answer(parent_author, replier) do
    {:ok, parent} = Posts.create_post(parent_author, %{body: "Eine Frage."})
    {:ok, reply} = Posts.create_reply(replier, parent, %{body: "Eine Antwort."})
    {parent, reply}
  end

  defp inboxes(post, type) do
    Delivery
    |> Repo.all()
    |> Enum.filter(fn delivery ->
      activity = Jason.decode!(delivery.activity_json)
      activity["type"] == type and String.ends_with?(activity["object"]["id"], post.id)
    end)
    |> Enum.map(& &1.inbox_uri)
    |> Enum.sort()
  end

  test "reaches the servers following the member it answers" do
    author = federating_member()
    replier = federating_member()
    inbox = remote_follower(author, "follows-author.example")

    {_parent, reply} = answer(author, replier)

    assert inboxes(reply, "Create") == [inbox]
  end

  test "still reaches the answering member's own followers, each server once" do
    author = federating_member()
    replier = federating_member()
    shared = remote_follower(author, "follows-both.example")
    ^shared = remote_follower(replier, "follows-both.example")
    own = remote_follower(replier, "follows-replier.example")

    {_parent, reply} = answer(author, replier)

    assert inboxes(reply, "Create") == Enum.sort([shared, own])
  end

  # Taken down after the answer went out: the edit that follows reaches only the
  # answering member's own followers, since the answered post is no longer
  # anything a stranger may read.
  test "does not widen past a parent that is not public" do
    author = federating_member()
    replier = federating_member()
    remote_follower(author, "follows-author.example")
    own = remote_follower(replier, "follows-replier.example")
    {parent, reply} = answer(author, replier)

    Repo.insert!(%PostDenial{post_id: parent.id, wildcard: "everyone"})
    Fediverse.federate_post_update(reply)

    assert inboxes(reply, "Update") == [own]
  end

  test "skips the followers of a member who no longer federates" do
    author = federating_member()
    replier = federating_member()
    remote_follower(author, "follows-author.example")
    {:ok, parent} = Posts.create_post(author, %{body: "Eine Frage."})

    author |> Ecto.Changeset.change(fediverse_followers?: false) |> Repo.update!()
    {:ok, reply} = Posts.create_reply(replier, parent, %{body: "Eine Antwort."})

    assert inboxes(reply, "Create") == []
  end
end
