defmodule Vutuv.FediverseReplyThreadingTest do
  @moduledoc """
  What a vutuv answer tells the rest of the network about the post it answers
  (issue #1739): `inReplyTo` for every answer, and the `cc`/`Mention` naming the
  answered author only when that author takes part.

  The split is the whole point, so both halves are pinned here — including the
  answer to a member who keeps out, whose `inReplyTo` deliberately points at an
  id no remote server can dereference.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Posts
  alias Vutuv.Posts.PostDenial
  alias VutuvWeb.Fediverse.Docs

  # An underscore, never the factory's default `user-N`: the mention grammar is
  # `[A-Za-z0-9_]+`, so a hyphenated handle reads as `@user` and the answer that
  # names it does not save at all.
  defp federating_user,
    do: federating_member(username: "member_#{System.unique_integer([:positive])}")

  defp reply_to(parent_author, body \\ "Eine Antwort.") do
    replier = federating_user()
    {:ok, parent} = Posts.create_post(parent_author, %{body: "Eine Frage."})
    {:ok, reply} = Posts.create_reply(replier, parent, %{body: body})

    {parent, reply, replier}
  end

  defp note(post, author), do: post |> Repo.preload(Docs.note_preloads()) |> Docs.note(author)

  defp mentions(note), do: Enum.filter(note["tag"] || [], &(&1["type"] == "Mention"))

  describe "an author who keeps out of the Fediverse" do
    test "is still what the answer points at, so it travels as a reply" do
      author = insert(:activated_user)
      refute Fediverse.federated?(author)

      {parent, reply, replier} = reply_to(author)

      assert note(reply, replier)["inReplyTo"] == Docs.note_url(author, parent.id)
    end

    test "is not named as an actor, because they serve no actor document" do
      author = insert(:activated_user)
      {_parent, reply, replier} = reply_to(author)

      note = note(reply, replier)

      assert note["cc"] == [Docs.followers_url(replier)]
      assert mentions(note) == []
    end
  end

  describe "an author who takes part" do
    test "is pointed at, named in cc and tagged as a Mention" do
      author = federating_user()
      {parent, reply, replier} = reply_to(author)

      note = note(reply, replier)

      assert note["inReplyTo"] == Docs.note_url(author, parent.id)
      assert note["cc"] == [Docs.followers_url(replier), Docs.actor_url(author)]

      assert [%{"href" => href, "name" => name}] = mentions(note)
      assert href == Docs.actor_url(author)
      assert name == Docs.handle(author)
    end

    test "is tagged once even when the answer's own text names them too" do
      author = federating_user()
      {_parent, reply, replier} = reply_to(author, "@#{author.username} ja, klar.")

      assert [%{"href" => href}] = mentions(note(reply, replier))
      assert href == Docs.actor_url(author)
    end
  end

  describe "a parent that cannot be pointed at" do
    test "is skipped when it has been taken down" do
      author = federating_user()
      {parent, reply, replier} = reply_to(author)
      Repo.insert!(%PostDenial{post_id: parent.id, wildcard: "everyone"})

      note = note(reply, replier)

      refute Map.has_key?(note, "inReplyTo")
      assert mentions(note) == []
    end

    # `parent_post_id` nilifies on delete while `parent_author_id` survives, so
    # the answer still names an author whose post is gone. Reading the id without
    # checking it hands `Posts.restricted?/1` a `%Post{id: nil}`, and that RAISES
    # on `d.post_id == ^nil` rather than answering nothing — a 500 on publishing
    # any answer to a deleted post.
    test "is skipped when the parent post has been deleted" do
      author = federating_user()
      {parent, reply, replier} = reply_to(author)
      {:ok, _} = Posts.delete_post(parent)

      note = note(Repo.reload!(reply), replier)

      refute Map.has_key?(note, "inReplyTo")
      assert mentions(note) == []
    end
  end
end
