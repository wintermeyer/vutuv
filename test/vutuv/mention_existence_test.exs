defmodule Vutuv.MentionExistenceTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Chat.Message
  alias Vutuv.Mentions
  alias Vutuv.Posts.Post

  describe "Post.changeset mention-existence validation" do
    test "accepts a mention of an existing member" do
      insert(:user, username: "alice")
      assert Post.changeset(%Post{}, %{body: "hi @alice"}).valid?
    end

    test "accepts a mention of an organization handle (shared namespace)" do
      insert(:organization, username: "acme")
      assert Post.changeset(%Post{}, %{body: "join @acme"}).valid?
    end

    test "rejects a mention of a handle nobody holds" do
      changeset = Post.changeset(%Post{}, %{body: "hi @ghost"})
      refute changeset.valid?
      assert %{body: [message]} = errors_on(changeset)
      assert message =~ "@ghost"
    end

    test "a handle inside a code span is sample text, not a mention" do
      assert Post.changeset(%Post{}, %{body: "type `@ghost` to mention"}).valid?
    end

    test "matches the whole handle: @old existing does not validate @older" do
      insert(:user, username: "old")
      assert Post.changeset(%Post{}, %{body: "hi @old"}).valid?
      refute Post.changeset(%Post{}, %{body: "hi @older"}).valid?
    end

    test "a fediverse @user@host handle needs no local account" do
      assert Post.changeset(%Post{}, %{body: "boost @bob@geno.social"}).valid?
    end
  end

  describe "Message.changeset" do
    test "rejects a DM mentioning a handle nobody holds" do
      refute Message.changeset(%Message{}, %{body: "psst @ghost"}).valid?
    end

    test "accepts a DM mentioning an existing member" do
      insert(:user, username: "alice")
      assert Message.changeset(%Message{}, %{body: "psst @alice"}).valid?
    end
  end

  describe "without_existence_check/1 (the LinkedIn import bypass)" do
    test "relaxes the check for the duration of the function" do
      changeset =
        Mentions.without_existence_check(fn ->
          Post.changeset(%Post{}, %{body: "hi @ghost"})
        end)

      assert changeset.valid?
    end

    test "restores the check afterwards" do
      Mentions.without_existence_check(fn -> :ok end)
      refute Post.changeset(%Post{}, %{body: "hi @ghost"}).valid?
    end
  end
end
