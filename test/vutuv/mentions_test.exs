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

    # The Milkdown WYSIWYG editor serializes `@ulrich_wolf` as `@ulrich\_wolf`
    # (remark escapes the `_`, a Markdown emphasis char). Earmark undoes that
    # before the renderer links the mention, but this module reads the raw
    # Markdown source, where the stray backslash used to truncate the handle to
    # `@ulrich` — the "@ulrich does not exist" the composer reported.
    test "sees through a Markdown-escaped underscore in a handle" do
      assert Mentions.local_handles("mit @ulrich\\_wolf gesprochen") == ["ulrich_wolf"]
    end

    test "sees through several escaped underscores in one handle" do
      assert Mentions.local_handles("@a\\_b\\_c") == ["a_b_c"]
    end

    test "an escaped and a bare form of the same handle de-duplicate" do
      assert Mentions.local_handles("@ulrich\\_wolf and @ulrich_wolf") == ["ulrich_wolf"]
    end

    test "a stray backslash does not invent a mention where the @ is escaped away" do
      # `\@handle` still resolves to the handle (the grammar ignores the escape
      # of the `@` itself, matching the renderer), but a lone `\_foo` is not one.
      assert Mentions.local_handles("plain \\_foo\\_ prose") == []
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
