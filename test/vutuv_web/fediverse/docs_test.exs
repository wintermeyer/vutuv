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
