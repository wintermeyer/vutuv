defmodule Vutuv.HandleAvailabilityTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Accounts.User
  alias Vutuv.Mentions
  alias Vutuv.Organizations.Organization
  alias Vutuv.SlugHelpers

  # `insert(:post, ...)` bypasses the changeset, so it can seed a post that
  # mentions a handle nobody holds — exactly the "freed handle still linked"
  # state the anti-hijack rule guards against.

  describe "mentioned_in_posts?/1" do
    test "detects a real @handle mention in a post body" do
      insert(:post, body: "shout out to @ghost")
      assert Mentions.mentioned_in_posts?("ghost")
      assert Mentions.mentioned_in_posts?("@GHOST")
    end

    test "is false for a handle no post mentions" do
      insert(:post, body: "nothing to see")
      refute Mentions.mentioned_in_posts?("ghost")
    end

    test "ignores a handle that only appears inside code" do
      insert(:post, body: "run `@ghost` locally")
      refute Mentions.mentioned_in_posts?("ghost")
    end
  end

  describe "username_changeset anti-hijack" do
    test "rejects a handle already used in a post" do
      insert(:post, body: "hi @ghost")
      changeset = User.username_changeset(%User{}, %{"username" => "ghost"})
      refute changeset.valid?
      assert %{username: [message]} = errors_on(changeset)
      assert message =~ "post"
    end

    test "a handle in no post stays claimable" do
      assert User.username_changeset(%User{}, %{"username" => "freename"}).valid?
    end

    test "grammar errors still win (no scan on an invalid handle)" do
      changeset = User.username_changeset(%User{}, %{"username" => "NO"})
      refute changeset.valid?
    end
  end

  describe "organization handle_changeset anti-hijack" do
    test "rejects a handle already used in a post" do
      insert(:post, body: "hi @ghost")
      refute Organization.handle_changeset(%Organization{}, %{"username" => "ghost"}).valid?
    end
  end

  describe "gen_handle_unique/4 avoids mentioned handles" do
    test "a name that would generate a post-mentioned handle gets a suffix instead" do
      insert(:post, body: "hi @coolname")
      handle = SlugHelpers.gen_handle_unique("coolname", User, :username, [])
      refute handle == "coolname"
    end

    test "a name whose handle is used nowhere is generated verbatim" do
      assert SlugHelpers.gen_handle_unique("uniquename", User, :username, []) == "uniquename"
    end
  end
end
