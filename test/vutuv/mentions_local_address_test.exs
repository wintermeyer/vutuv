defmodule Vutuv.MentionsLocalAddressTest do
  @moduledoc """
  An address on **our own** host is a mention (issue #1560).

  `@ada@vutuv.de` and `@ada` name the same member — the first is simply the
  address written out in full, which is how every other server writes a mention
  of one of us. So all four concerns `Vutuv.Mentions` keeps in step have to see
  it: the renderer's link, the notification, the per-post cap and the rename
  rewrite. Before this, `local_handles/1` dropped every `@user@host` hit by
  design, so being named that way notified nobody and survived a rename as a
  link to a handle its owner had left.

  `async: false` and its own file because `with_endpoint_host/1` changes global
  endpoint config the SQL sandbox does not roll back: the test endpoint answers
  "localhost", which has no dot and therefore cannot match the address half of
  the entity grammar at all.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.EndpointHostHelper
  import Vutuv.PostsHelpers

  alias Vutuv.Accounts
  alias Vutuv.Mentions
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostMention

  setup do
    with_endpoint_host("vutuv.test")
    :ok
  end

  defp mentionable(attrs \\ []) do
    insert(:activated_user, Keyword.put_new(attrs, :username, unique_username()))
  end

  describe "local_handles/1" do
    test "an address on our own host is the same mention as the bare handle" do
      assert Mentions.local_handles("hi @ada@vutuv.test!") == ["ada"]
    end

    test "the www alias and a shouted host are the same installation" do
      assert Mentions.local_handles("@ada@www.vutuv.test") == ["ada"]
      assert Mentions.local_handles("@ada@VUTUV.TEST") == ["ada"]
    end

    test "both spellings of one member collapse to one handle" do
      assert Mentions.local_handles("@ada and @Ada@vutuv.test") == ["ada"]
    end

    test "an address on another server is still nobody here" do
      assert Mentions.local_handles("say hi to @bob@geno.social") == []
      assert Mentions.local_handles("@them@vutuv.test.evil.example") == []
    end

    test "our tag host names a topic, not a member" do
      assert Mentions.local_handles("@php@tags.vutuv.test") == []
    end

    test "a slash in front of the address does not hide the member" do
      assert Mentions.local_handles("Bündnis 90/@ada@vutuv.test") == ["ada"]
    end

    test "an address inside a code span is sample text" do
      assert Mentions.local_handles("type `@ada@vutuv.test` to mention") == []
    end
  end

  describe "hashtags/1" do
    test "a topic's address on our tag host names that tag" do
      assert Mentions.hashtags("read @php@tags.vutuv.test") == ["php"]
    end

    test "the address and the hashtag spelling collapse to one tag" do
      assert Mentions.hashtags("#PHP and @php@tags.vutuv.test") == ["php"]
    end

    test "an address on our main host or another server is not a tag" do
      assert Mentions.hashtags("@ada@vutuv.test and @bob@geno.social") == []
    end
  end

  describe "rewrite/3" do
    test "rewrites the full address and keeps the host as written" do
      assert Mentions.rewrite("hi @old@vutuv.test!", "old", "new") ==
               {"hi @new@vutuv.test!", 1}

      assert Mentions.rewrite("hi @Old@WWW.vutuv.test", "old", "new") ==
               {"hi @new@WWW.vutuv.test", 1}
    end

    test "counts both spellings of the same member" do
      assert Mentions.rewrite("@old and @old@vutuv.test", "old", "new") ==
               {"@new and @new@vutuv.test", 2}
    end

    test "leaves an address on another server alone" do
      text = "boost @old@geno.social and @old@tags.vutuv.test"
      assert Mentions.rewrite(text, "old", "new") == {text, 0}
    end

    test "never touches an address inside a code span" do
      text = "code `@old@vutuv.test`"
      assert Mentions.rewrite(text, "old", "new") == {text, 0}
    end
  end

  describe "existence validation" do
    test "accepts a full address of a member who exists" do
      handle = unique_username()
      insert(:user, username: handle)
      assert Post.changeset(%Post{}, %{body: "hi @#{handle}@vutuv.test"}).valid?
    end

    test "rejects a full address of a handle nobody holds" do
      changeset = Post.changeset(%Post{}, %{body: "hi @ghost@vutuv.test"})
      refute changeset.valid?
      assert %{body: [message]} = errors_on(changeset)
      assert message =~ "@ghost"
    end

    test "an address on another server still needs no local account" do
      assert Post.changeset(%Post{}, %{body: "boost @ghost@geno.social"}).valid?
    end
  end

  describe "the per-post cap" do
    test "the full address counts, and counts as the same account" do
      handles = for _ <- 1..Mentions.max_post_mentions(), do: unique_username()
      Enum.each(handles, &insert(:user, username: &1))
      extra = unique_username()
      insert(:user, username: extra)

      at_cap = Enum.map_join(handles, " ", &"@#{&1}@vutuv.test")
      assert Post.changeset(%Post{}, %{body: at_cap}).valid?

      # The same five spelled both ways are still five accounts.
      both_ways = at_cap <> " " <> Enum.map_join(handles, " ", &"@#{&1}")
      assert Post.changeset(%Post{}, %{body: both_ways}).valid?

      changeset = Post.changeset(%Post{}, %{body: at_cap <> " @#{extra}@vutuv.test"})
      refute changeset.valid?
      assert %{body: [message]} = errors_on(changeset)
      assert message =~ "#{Mentions.max_post_mentions()}"
    end
  end

  describe "being named by their address is a notification" do
    test "a post naming a member in full records the mention" do
      author = mentionable()
      mentioned = mentionable()

      create_post!(author, %{body: "Ask @#{mentioned.username}@vutuv.test about it."})

      assert [%PostMention{user_id: user_id}] = Repo.all(PostMention)
      assert user_id == mentioned.id
    end

    test "naming the same member both ways records one mention" do
      author = mentionable()
      mentioned = mentionable()
      handle = mentioned.username

      create_post!(author, %{body: "@#{handle} — that is @#{handle}@vutuv.test"})

      assert [%PostMention{user_id: user_id}] = Repo.all(PostMention)
      assert user_id == mentioned.id
    end
  end

  describe "availability and rename propagation" do
    test "a handle linked only by its full address is not claimable" do
      insert(:post, body: "shout out to @ghost@vutuv.test")
      assert Mentions.mentioned_in_posts?("ghost")
      assert Mentions.count_post_mentions("ghost") == 1
    end

    test "a rename rewrites the full address across the surfaces" do
      victim = insert(:user, username: "oldname")
      author = insert(:user, username: "writer")
      post = insert(:post, user: author, body: "great point @oldname@vutuv.test!")

      assert {:ok, _} = Accounts.update_username(victim, %{"username" => "newname"})
      assert Repo.get!(Post, post.id).body == "great point @newname@vutuv.test!"
      refute Mentions.mentioned_in_posts?("oldname")
    end
  end
end
