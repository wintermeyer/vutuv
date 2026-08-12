defmodule VutuvWeb.Fediverse.DocsTest do
  # The ActivityPub JSON documents: the actor (the member's machine-readable
  # identity, with the public key Mastodon verifies deliveries against) and
  # the Note/activity wrappers for public posts.
  use Vutuv.DataCase, async: true

  alias Vutuv.Fediverse
  alias VutuvWeb.Fediverse.Docs

  defp base, do: VutuvWeb.Endpoint.url()

  describe "actor/2" do
    test "renders a Person with inbox, followers and the public key" do
      user = insert(:activated_user, headline: "Grüße aus <Koblenz>")
      {:ok, actor} = Fediverse.ensure_actor(user)

      doc = Docs.actor(user, actor)

      assert doc["type"] == "Person"
      assert doc["id"] == "#{base()}/#{user.username}/actor"
      assert doc["preferredUsername"] == user.username
      assert doc["inbox"] == "#{base()}/#{user.username}/actor/inbox"
      assert doc["followers"] == "#{base()}/#{user.username}/actor/followers"
      assert doc["url"] == "#{base()}/#{user.username}"
      assert doc["manuallyApprovesFollowers"] == false
      assert doc["publicKey"]["id"] == "#{base()}/#{user.username}/actor#main-key"
      assert doc["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
      # The summary is HTML with the member content escaped.
      assert doc["summary"] =~ "&lt;Koblenz&gt;"
      # The avatar rides as the scraper-friendly square JPEG.
      assert doc["icon"]["url"] == "#{base()}/#{user.username}/avatar.jpg"
    end

    test "renders alsoKnownAs only when the member listed origin accounts (#986)" do
      user =
        insert(:activated_user,
          also_known_as: [
            "https://mastodon.social/users/alice",
            "https://fosstodon.org/users/alice"
          ]
        )

      {:ok, actor} = Fediverse.ensure_actor(user)

      assert Docs.actor(user, actor)["alsoKnownAs"] == [
               "https://mastodon.social/users/alice",
               "https://fosstodon.org/users/alice"
             ]
    end

    test "omits alsoKnownAs entirely when empty (absent, never an empty array)" do
      user = insert(:activated_user, also_known_as: [])
      {:ok, actor} = Fediverse.ensure_actor(user)

      refute Map.has_key?(Docs.actor(user, actor), "alsoKnownAs")
    end

    test "renders movedTo only after a move-out (#986 half 2)" do
      moved = insert(:activated_user, moved_to: "https://mastodon.social/users/gone")
      staying = insert(:activated_user)
      {:ok, ma} = Fediverse.ensure_actor(moved)
      {:ok, sa} = Fediverse.ensure_actor(staying)

      assert Docs.actor(moved, ma)["movedTo"] == "https://mastodon.social/users/gone"
      refute Map.has_key?(Docs.actor(staying, sa), "movedTo")
    end
  end

  describe "move_activity/2 (#986 half 2)" do
    test "the Move names the member as actor and object, the target as target" do
      user = insert(:activated_user)
      target = "https://mastodon.social/users/gone"

      activity = Docs.move_activity(user, target)

      assert activity["type"] == "Move"
      assert activity["actor"] == "#{base()}/#{user.username}/actor"
      assert activity["object"] == activity["actor"]
      assert activity["target"] == target
      assert activity["to"] == ["#{base()}/#{user.username}/actor/followers"]
    end
  end

  describe "create_activity/2 (public post -> Create(Note))" do
    test "wraps the post as a public Note addressed to the followers" do
      user = insert(:activated_user)
      post = insert(:post, user: user, body: "Hallo **Fediverse**!")

      activity = Docs.create_activity(post, user)
      note = activity["object"]

      assert activity["type"] == "Create"
      assert activity["actor"] == "#{base()}/#{user.username}/actor"
      assert activity["to"] == ["https://www.w3.org/ns/activitystreams#Public"]
      assert activity["cc"] == ["#{base()}/#{user.username}/actor/followers"]

      assert note["type"] == "Note"
      assert note["id"] == "#{base()}/#{user.username}/posts/#{post.id}"
      assert note["attributedTo"] == activity["actor"]
      assert note["content"] =~ "<strong>Fediverse</strong>"
      assert note["published"] =~ ~r/Z$/
    end

    test "relative links in the body arrive absolute" do
      author = insert(:activated_user)
      mentioned = insert(:activated_user, username: "erwaehnte_person")
      post = insert(:post, user: author, body: "Hi @#{mentioned.username}!")

      note = Docs.create_activity(post, author)["object"]

      assert note["content"] =~ ~s(href="#{base()}/#{mentioned.username}")
      refute note["content"] =~ ~s(href="/#{mentioned.username}")
    end

    test "a protocol-relative //host link is left alone, not prefixed with base" do
      author = insert(:activated_user)
      post = insert(:post, user: author, body: "See [this](//evil.com)")

      note = Docs.create_activity(post, author)["object"]

      # The negative lookahead must skip `//`: prefixing it would corrupt the
      # link into `#{base()}//evil.com`.
      assert note["content"] =~ ~s(href="//evil.com")
      refute note["content"] =~ ~s(href="#{base()}//evil.com")
    end
  end

  describe "hashtags on an outgoing note (#1421)" do
    # The composer's chips and a `#hashtag` in the body are two different
    # tables here (`post_tags` / `post_hashtags`), and only the second is
    # written in the text. Both have to reach the other side, in the two ways
    # the fediverse spells this.
    defp tagged_note(author, attrs) do
      {:ok, post} = Vutuv.Posts.create_post(author, attrs)

      post
      |> Vutuv.Repo.preload(Docs.note_preloads())
      |> Docs.create_activity(author)
      |> Map.fetch!("object")
    end

    defp hashtag_names(note) do
      note["tag"]
      |> List.wrap()
      |> Enum.filter(&(&1["type"] == "Hashtag"))
      |> Enum.map(& &1["name"])
    end

    # A tag name is a shared LOOKUP key even though only the slug is unique, so
    # every tag here is minted per test (the async rule in the Elixir guidelines).
    defp mint_tag(prefix) do
      n = System.unique_integer([:positive])
      insert(:tag, name: "#{prefix}#{n}", slug: "#{String.downcase(prefix)}#{n}")
    end

    test "a chip travels as a Hashtag object and as a closing line" do
      author = insert(:activated_user)
      tag = mint_tag("Elixir")

      note = tagged_note(author, %{body: "Wir bauen etwas.", tags: tag.name})

      # What a remote server indexes, and what makes a hashtag follow reach it.
      assert hashtag_names(note) == ["##{tag.name}"]
      assert [object] = note["tag"]
      assert object["href"] == "#{base()}/tags/#{tag.slug}"

      # And what a reader sees: a chip stands nowhere in the text, so the note
      # ends with it. Mastodon's spec promises nothing about a tag that appears
      # only in the array, and a server that merely renders `content` shows none.
      assert note["content"] =~ ~s(rel="tag")
      assert note["content"] =~ "##{tag.name}"
    end

    test "a hashtag already written in the body gets an object but no second line" do
      author = insert(:activated_user)
      tag = mint_tag("elixir")

      note = tagged_note(author, %{body: "Wir bauen mit ##{tag.name}."})

      assert hashtag_names(note) == ["##{tag.name}"]
      # Exactly one occurrence: appending it again would print it twice.
      assert note["content"] |> String.split("##{tag.name}") |> length() == 2
    end

    test "the same tag as chip and hashtag is one object and is not appended" do
      author = insert(:activated_user)
      tag = mint_tag("elixir")

      note = tagged_note(author, %{body: "Wir bauen mit ##{tag.name}.", tags: tag.name})

      assert hashtag_names(note) == ["##{tag.name}"]
      assert note["content"] |> String.split("##{tag.name}") |> length() == 2
    end

    test "a multi-word tag loses its separator instead of breaking in half" do
      author = insert(:activated_user)
      n = System.unique_integer([:positive])
      tag = insert(:tag, name: "Machine Learning #{n}", slug: "machine_learning_#{n}")

      note = tagged_note(author, %{body: "Kurz notiert.", tags: tag.name})

      # Mastodon's hashtag charset is alphanumerics, `_` and a couple of Unicode
      # separators; a hyphen is not in it (`HASHTAG_INVALID_CHARS_RE`), so the
      # slug is the wrong source — `#machine-learning` would arrive as the tag
      # "machine" with loose text trailing it.
      assert hashtag_names(note) == ["#MachineLearning#{n}"]
      # The link still points at the tag page, which keeps its own spelling.
      assert [object] = note["tag"]
      assert object["href"] == "#{base()}/tags/#{tag.slug}"
    end

    test "a tag that cannot become a hashtag is left out, never sent as a bare #" do
      author = insert(:activated_user)
      n = System.unique_integer([:positive])
      tag = insert(:tag, name: "***", slug: "sternchen_#{n}")
      {:ok, post} = Vutuv.Posts.create_post(author, %{body: "Kurz notiert."})

      # Filed directly: a punctuation-only name is legacy data the composer no
      # longer mints, and going through it would make this pass for the wrong
      # reason (no tag attached at all).
      Vutuv.Repo.insert!(%Vutuv.Posts.PostTag{post_id: post.id, tag_id: tag.id})

      note =
        post
        |> Vutuv.Repo.preload(Docs.note_preloads())
        |> Docs.create_activity(author)
        |> Map.fetch!("object")

      assert hashtag_names(note) == []
      refute note["content"] =~ ~s(rel="tag")
    end

    test "a post without tags carries no tag array at all" do
      author = insert(:activated_user)

      note = tagged_note(author, %{body: "Nichts weiter."})

      refute Map.has_key?(note, "tag")
      refute note["content"] =~ ~s(rel="tag")
    end
  end

  describe "update_activity/2 and delete_activity/2" do
    test "update wraps the same note under an Update id" do
      user = insert(:activated_user)
      post = insert(:post, user: user)

      activity = Docs.update_activity(post, user)

      assert activity["type"] == "Update"
      assert activity["object"]["id"] == "#{base()}/#{user.username}/posts/#{post.id}"
    end

    test "delete tombstones the note id" do
      user = insert(:activated_user)
      post = insert(:post, user: user)

      activity = Docs.delete_activity(post.id, user)

      assert activity["type"] == "Delete"
      assert activity["object"]["type"] == "Tombstone"
      assert activity["object"]["id"] == "#{base()}/#{user.username}/posts/#{post.id}"
    end
  end

  describe "accept_activity/2" do
    test "echoes the Follow back under the member's actor" do
      user = insert(:activated_user)

      follow = %{
        "id" => "https://social.example/activities/1",
        "type" => "Follow",
        "actor" => "https://social.example/users/alice",
        "object" => "#{base()}/#{user.username}/actor"
      }

      activity = Docs.accept_activity(user, follow)

      assert activity["type"] == "Accept"
      assert activity["actor"] == "#{base()}/#{user.username}/actor"
      assert activity["object"] == follow
    end
  end
end
