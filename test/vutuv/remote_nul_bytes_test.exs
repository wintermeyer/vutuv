defmodule Vutuv.RemoteNulBytesTest do
  @moduledoc """
  A NUL byte is valid UTF-8 and Postgres refuses it (`22021
  character_not_in_repertoire`), so one in a stored string is not a display
  glitch — it is a raise on `Repo.insert`, and every column here is written
  from a document a stranger's server wrote (issue #1767).

  `Vutuv.RemoteHtml` scrubs the *bodies* it reduces to text. The display
  strings beside them (an actor's handle and name, a reaction's emoji, the
  URIs) never go near it: they are copied out of the JSON, truncated, and cast.
  So the guard belongs at the write, and this asserts it there — through the
  real changeset and a real insert, because a changeset-only assertion would
  pass on the unguarded code too.
  """
  use Vutuv.DataCase

  alias Vutuv.Fediverse.Follower
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.Reaction
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.UUIDv7

  # What a hostile actor document puts in `preferredUsername`, `name` or an
  # `EmojiReact` content: a raw NUL, not the `&#0;` entity the HTML path
  # already defuses.
  @nul <<0>>

  test "a remote actor's handle and name reach the accounts table clean" do
    assert {:ok, account} =
             %RemoteAccount{}
             |> RemoteAccount.changeset(%{
               actor_uri: "https://remote.example/users/nul",
               host: "remote.example",
               handle: "nul" <> @nul <> "user",
               name: "Nul" <> @nul <> "Name",
               summary: "Ein" <> @nul <> "Text",
               inbox_uri: "https://remote.example/users/nul/inbox"
             })
             |> Repo.insert()

    assert account.handle == "nuluser"
    assert account.name == "NulName"
    assert account.summary == "EinText"
  end

  test "so do a follower's" do
    user = insert(:user)

    assert {:ok, follower} =
             %Follower{user_id: user.id}
             |> Follower.changeset(%{
               actor_uri: "https://remote.example/users/nulf",
               inbox_uri: "https://remote.example/users/nulf/inbox",
               handle: "nul" <> @nul <> "f",
               name: "Nul" <> @nul <> "F"
             })
             |> Repo.insert()

    assert follower.handle == "nulf"
    assert follower.name == "NulF"
  end

  test "and a stored reply's actor strings" do
    post = insert(:post)
    received = DateTime.utc_now(:second)

    assert {:ok, note} =
             %Note{post_id: post.id}
             |> Note.changeset(%{
               object_uri: "https://remote.example/notes/nul",
               actor_uri: "https://remote.example/users/nul",
               handle: "nul" <> @nul <> "user",
               display_name: "Nul" <> @nul <> "Name",
               content_text: "Eine Antwort",
               audience: "public",
               received_at: received,
               expires_at: DateTime.add(received, 86_400)
             })
             |> Repo.insert()

    assert note.handle == "nuluser"
    assert note.display_name == "NulName"
  end

  test "and a reaction's handle, which the changeset only validates" do
    post = insert(:post)

    changeset =
      %Reaction{post_id: post.id}
      |> Reaction.changeset(%{
        actor_uri: "https://remote.example/users/nul",
        handle: "nul" <> @nul <> "user",
        kind: "like",
        received_at: DateTime.utc_now(:second)
      })

    # This path validates with the changeset and then writes the applied struct
    # with `insert_all`, so whatever the changeset holds is what Postgres sees —
    # a scrub that only ran inside `Repo.insert/1` would miss it.
    assert {:ok, reaction} = Ecto.Changeset.apply_action(changeset, :insert)
    assert reaction.handle == "nuluser"

    assert {1, _rows} =
             Repo.insert_all(Reaction, [
               %{
                 id: UUIDv7.generate(),
                 post_id: post.id,
                 actor_uri: reaction.actor_uri,
                 handle: reaction.handle,
                 kind: reaction.kind,
                 received_at: reaction.received_at
               }
             ])
  end

  test "and a cached post's own URIs" do
    assert {:ok, remote_post} = insert_remote_post(@nul)

    assert remote_post.object_uri == "https://remote.example/posts/nul"
    assert remote_post.origin_url == "https://remote.example/@nul/1"
  end

  test "and an attachment's alt text, which its author writes" do
    {:ok, remote_post} = insert_remote_post("")

    assert {:ok, image} =
             %RemoteImage{remote_post_id: remote_post.id}
             |> RemoteImage.changeset(%{
               source_uri: "https://remote.example/media/1.jpg",
               alt: "Eine" <> @nul <> "Beschreibung"
             })
             |> Repo.insert()

    assert image.alt == "EineBeschreibung"
  end

  defp insert_remote_post(suffix) do
    received = DateTime.utc_now(:second)
    n = System.unique_integer([:positive])

    {:ok, account} =
      %RemoteAccount{}
      |> RemoteAccount.changeset(%{
        actor_uri: "https://remote.example/users/author#{n}",
        host: "remote.example",
        inbox_uri: "https://remote.example/users/author#{n}/inbox"
      })
      |> Repo.insert()

    %RemotePost{remote_account_id: account.id}
    |> RemotePost.changeset(%{
      object_uri: "https://remote.example/posts/nul" <> suffix,
      origin_url: "https://remote.example/@nul/1" <> suffix,
      content_text: "Ein Beitrag",
      audience: "public",
      kind: "note",
      published_at: received,
      received_at: received,
      expires_at: DateTime.add(received, 86_400)
    })
    |> Repo.insert()
  end
end
