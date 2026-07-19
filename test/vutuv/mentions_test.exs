defmodule Vutuv.MentionsTest do
  use ExUnit.Case, async: true

  alias Vutuv.Mentions

  describe "local_handles/1" do
    test "collects local @handles, lowercased and de-duplicated in order" do
      assert Mentions.local_handles("hi @Alice and @bob and @alice") == ["alice", "bob"]
    end

    test "an email address is not a mention (@ sits mid-token)" do
      assert Mentions.local_handles("write to bob@old.de please") == []
    end

    test "captures the whole handle, so @old is not found inside @older" do
      assert Mentions.local_handles("@older") == ["older"]
    end

    test "a fediverse @user@host handle is not a local mention" do
      assert Mentions.local_handles("say hi to @bob@geno.social") == []
    end

    test "a #hashtag is not a mention" do
      assert Mentions.local_handles("#elixir is nice") == []
    end

    test "a handle inside inline code is sample text, not a mention" do
      assert Mentions.local_handles("type `@example` to mention") == []
    end

    test "a handle inside a fenced code block is sample text, not a mention" do
      assert Mentions.local_handles("```\nping @example\n```") == []
    end

    test "nil / non-binary is empty" do
      assert Mentions.local_handles(nil) == []
    end
  end

  describe "mentions?/2" do
    test "matches case-insensitively, with the @ optional" do
      assert Mentions.mentions?("hey @Bob", "bob")
      assert Mentions.mentions?("hey @Bob", "@BOB")
    end

    test "does not match a longer handle" do
      refute Mentions.mentions?("hey @Bobby", "bob")
    end
  end

  describe "rewrite/3" do
    test "rewrites a local mention and reports the count" do
      assert Mentions.rewrite("hi @old!", "old", "new") == {"hi @new!", 1}
    end

    test "matches case-insensitively but writes the canonical lowercase handle" do
      assert Mentions.rewrite("hi @Old and @OLD", "old", "new") == {"hi @new and @new", 2}
    end

    test "leaves @older untouched (whole-handle match only)" do
      assert Mentions.rewrite("@older and @old", "old", "new") == {"@older and @new", 1}
    end

    test "never touches emails, hashtags, fediverse handles or code spans" do
      text = "mail bob@old.de, tag #old, boost @old@host.io, code `@old`"
      assert Mentions.rewrite(text, "old", "new") == {text, 0}
    end

    test "round-trips a code-only body byte-for-byte" do
      text = "```\n@old\n```\nthen `@old` inline"
      assert Mentions.rewrite(text, "old", "new") == {text, 0}
    end

    test "is a no-op when old equals new" do
      assert Mentions.rewrite("@old", "old", "old") == {"@old", 0}
    end

    test "nil body round-trips" do
      assert Mentions.rewrite(nil, "old", "new") == {nil, 0}
    end
  end
end
