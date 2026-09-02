defmodule Vutuv.RemoteUrlScrubTest do
  @moduledoc """
  A URL copied out of another server's JSON must never reach an `href` unchecked.

  `Phoenix.Component.link/1` calls `valid_destination!/2`, which **raises** for a
  scheme it does not know — it does not sanitize. So a remote post carrying
  `"url": "javascript:1"` does not render oddly, it takes down every render of
  the page that shows it: the socket dies, the client retries, and the member
  whose feed it is has no way to remove the post.

  `Vutuv.ChangesetHelpers.drop_non_web_urls/2` drops such a value at the write
  instead, the way `scrub_nul/1` drops a NUL byte. Dropped, never refused: these
  are optional display fields, and losing a link beats losing the post.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.ChangesetHelpers
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  describe "web_url?/1" do
    test "accepts an ordinary web address" do
      assert ChangesetHelpers.web_url?("https://social.example/@alice/1")
      assert ChangesetHelpers.web_url?("http://social.example/1")
    end

    # Every one of these raises inside `link/1` rather than being escaped.
    test "refuses everything that is not one" do
      refute ChangesetHelpers.web_url?("javascript:alert(1)")
      refute ChangesetHelpers.web_url?("data:text/html,<script>alert(1)</script>")
      refute ChangesetHelpers.web_url?("file:///etc/passwd")
      refute ChangesetHelpers.web_url?("foo:bar")
      # A scheme-less or hostless string is not a destination either.
      refute ChangesetHelpers.web_url?("/just/a/path")
      refute ChangesetHelpers.web_url?("https://")
      refute ChangesetHelpers.web_url?("")
      refute ChangesetHelpers.web_url?(nil)
    end
  end

  describe "a remote post" do
    defp post_attrs(overrides) do
      Map.merge(
        %{
          object_uri: "https://social.example/notes/#{System.unique_integer([:positive])}",
          content_text: "Sehr treffend.",
          audience: "public",
          kind: "note",
          published_at: DateTime.utc_now(:second),
          received_at: DateTime.utc_now(:second),
          expires_at: DateTime.add(DateTime.utc_now(:second), 86_400)
        },
        overrides
      )
    end

    test "keeps an ordinary permalink" do
      url = "https://social.example/@alice/1"
      changeset = RemotePost.changeset(%RemotePost{}, post_attrs(%{origin_url: url}))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :origin_url) == url
    end

    test "drops a hostile permalink but keeps the post" do
      changeset =
        RemotePost.changeset(%RemotePost{}, post_attrs(%{origin_url: "javascript:1"}))

      assert changeset.valid?, "the post must survive its own bad link"
      assert Ecto.Changeset.get_field(changeset, :origin_url) == nil
      assert Ecto.Changeset.get_field(changeset, :content_text) == "Sehr treffend."
    end

    test "drops a hostile quote URI" do
      changeset =
        RemotePost.changeset(%RemotePost{}, post_attrs(%{quote_uri: "data:text/html,x"}))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :quote_uri) == nil
    end
  end

  describe "a remote account" do
    test "drops a hostile actor URI and a hostile forwarding address" do
      changeset =
        RemoteAccount.changeset(%RemoteAccount{}, %{
          actor_uri: "javascript:1",
          host: "evil.example",
          handle: "@mallory@evil.example",
          inbox_uri: "https://evil.example/inbox",
          moved_to: "file:///etc/passwd"
        })

      assert Ecto.Changeset.get_field(changeset, :actor_uri) == nil
      assert Ecto.Changeset.get_field(changeset, :moved_to) == nil
      # The inbox is not an href — it is where we POST — so it is left alone.
      assert Ecto.Changeset.get_field(changeset, :inbox_uri) == "https://evil.example/inbox"
    end
  end
end
