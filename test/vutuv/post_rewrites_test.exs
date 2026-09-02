defmodule Vutuv.PostRewritesTest do
  @moduledoc """
  Per-author search-and-replace rules: the rewrite engine, its bounds, and the
  owner-scoped list.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.PostRewrites
  alias Vutuv.PostRewrites.PostRewrite

  @golem "@golemde@flipboard.com"
  @footer "Tablet Amazon Fire Max 11 mit Alexa stark reduziert\nhttps://www.golem.de/news/x.html \n\nGepostet in GOLEM @golem-Golemde"

  defp compiled(rules) do
    rules
    |> Enum.map(fn {account, pattern, replacement} ->
      %PostRewrite{account: account, pattern: pattern, replacement: replacement}
    end)
    |> PostRewrites.compile()
  end

  defp golem_post(text \\ @footer) do
    %RemotePost{
      content_text: text,
      remote_account: %RemoteAccount{
        handle: "Golemde",
        host: "flipboard.com",
        actor_uri: "https://flipboard.com/@Golemde"
      }
    }
  end

  describe "rewrite_text/2" do
    test "deletes the Flipboard footer with a multiline anchor and trims the blank it leaves" do
      [rules] = Map.values(compiled([{@golem, "^Gepostet in .*$", ""}]))

      assert PostRewrites.rewrite_text(@footer, rules) ==
               "Tablet Amazon Fire Max 11 mit Alexa stark reduziert\nhttps://www.golem.de/news/x.html"
    end

    test "runs the rules top to bottom, each on the previous one's output" do
      [down] = Map.values(compiled([{@golem, "a", "b"}, {@golem, "b", "c"}]))
      [up] = Map.values(compiled([{@golem, "b", "c"}, {@golem, "a", "b"}]))

      assert PostRewrites.rewrite_text("a", down) == "c"
      assert PostRewrites.rewrite_text("a", up) == "b"
    end

    test "replacement: \\1 is a group, \\0 the whole match, & a literal ampersand" do
      [rules] = Map.values(compiled([{@golem, "(Golem)\\.de", "\\1 & Co [\\0]"}]))

      assert PostRewrites.rewrite_text("Golem.de meldet", rules) == "Golem & Co [Golem.de] meldet"
    end

    test "an unchanged text comes back as the same binary" do
      [rules] = Map.values(compiled([{@golem, "nothing here", ""}]))
      text = "  padded  "

      assert PostRewrites.rewrite_text(text, rules) == text
    end

    test "a catastrophic pattern gives up within the step budget and changes nothing" do
      [rules] = Map.values(compiled([{@golem, "(a+)+$", "x"}]))
      subject = String.duplicate("a", 40) <> "b"

      {micros, result} = :timer.tc(fn -> PostRewrites.rewrite_text(subject, rules) end)

      assert result == subject
      assert micros < 50_000
    end
  end

  describe "rewrite/3" do
    test "rewrites a cached remote post whose author's handle matches, case-insensitively" do
      compiled = compiled([{"@GolemDE@flipboard.com", "^Gepostet in .*$", ""}])

      assert %RemotePost{content_text: text} = PostRewrites.rewrite(golem_post(), compiled, nil)
      refute text =~ "Gepostet"
    end

    test "leaves a post by another author alone" do
      compiled = compiled([{"@taz_de@flipboard.com", "^Gepostet in .*$", ""}])

      assert PostRewrites.rewrite(golem_post(), compiled, nil) == golem_post()
    end

    test "rewrites a member's post by their handle, but never the viewer's own" do
      author = insert(:activated_user, username: "erika")
      post = insert(:post, user: author, body: "Hallo -- Gruß Erika")
      compiled = compiled([{"@erika", " -- Gruß Erika", ""}])

      assert %{body: "Hallo"} = PostRewrites.rewrite(post, compiled, insert(:user).id)
      assert %{body: "Hallo -- Gruß Erika"} = PostRewrites.rewrite(post, compiled, author.id)
    end

    test "rewrites a reply from another network" do
      note = %Note{
        content_text: "Guter Punkt. -- sent from my phone",
        handle: "alice",
        actor_uri: "https://social.example/users/alice"
      }

      compiled = compiled([{"@alice@social.example", " -- sent from my phone", ""}])

      assert %Note{content_text: "Guter Punkt."} = PostRewrites.rewrite(note, compiled, nil)
    end

    test "a wordless post stays wordless" do
      compiled = compiled([{@golem, ".*", "x"}])
      post = golem_post(nil)

      assert PostRewrites.rewrite(post, compiled, nil) == post
    end
  end

  describe "rewrite_entry/3" do
    test "reaches the folded ancestors, the answered remote parent and the woven-in replies" do
      author = insert(:activated_user, username: "erika")
      post = insert(:post, user: author, body: "reply -- sig")
      parent = insert(:post, user: author, body: "parent -- sig")

      note = %Note{
        content_text: "note -- sig",
        handle: "erika",
        actor_uri: "https://vutuv.test/users/erika"
      }

      entry = %{
        post: post,
        ancestors: [parent],
        remote_parents: %{"p" => %{remote_post: golem_post("remote -- sig")}},
        remote_replies: %{post.id => [note]}
      }

      compiled =
        compiled([
          {"@erika", " -- sig", ""},
          {@golem, " -- sig", ""},
          {"@erika@vutuv.test", " -- sig", ""}
        ])

      rewritten = PostRewrites.rewrite_entry(entry, compiled, insert(:user).id)

      assert rewritten.post.body == "reply"
      assert [%{body: "parent"}] = rewritten.ancestors
      assert %{"p" => %{remote_post: %{content_text: "remote"}}} = rewritten.remote_parents
      assert [%{content_text: "note"}] = rewritten.remote_replies[post.id]
    end

    test "is a no-op without rules" do
      entry = %{remote_post: golem_post()}

      assert PostRewrites.rewrite_entry(entry, %{}, nil) == entry
    end
  end

  describe "segments/2" do
    test "cuts the text around the rule's matches and skips empty ones" do
      {:ok, rule} = PostRewrites.compile_rule("o", "")

      assert PostRewrites.segments("foo bar", rule) ==
               [{:plain, "f"}, {:hit, "o"}, {:hit, "o"}, {:plain, " bar"}]

      {:ok, anchor} = PostRewrites.compile_rule("^", "")
      assert PostRewrites.segments("foo", anchor) == [{:plain, "foo"}]
    end

    test "keeps multi-byte characters whole" do
      {:ok, rule} = PostRewrites.compile_rule("ü", "")

      assert PostRewrites.segments("Grüße", rule) == [{:plain, "Gr"}, {:hit, "ü"}, {:plain, "ße"}]
    end
  end

  describe "the list" do
    setup do
      %{user: insert(:activated_user), other: insert(:activated_user)}
    end

    test "creates in order, moves within the account only, and deletes", %{user: user} do
      {:ok, a} = PostRewrites.create_rule(user, "GolemDE@flipboard.com", %{pattern: "a"})
      {:ok, b} = PostRewrites.create_rule(user, @golem, %{pattern: "b", replacement: ""})
      {:ok, _taz} = PostRewrites.create_rule(user, "@taz_de@flipboard.com", %{pattern: "t"})

      assert a.account == @golem
      assert a.position == 1 and b.position == 2

      assert :ok = PostRewrites.move_rule(user, b.id, :up)
      assert [%{id: bid}, %{id: aid}] = PostRewrites.list_for_account(user, @golem)
      assert {bid, aid} == {b.id, a.id}

      # Already on top: stays put, and the other account is not touched.
      assert :ok = PostRewrites.move_rule(user, b.id, :up)
      assert [%{id: ^bid}, %{id: ^aid}] = PostRewrites.list_for_account(user, @golem)
      assert [%{position: 1}] = PostRewrites.list_for_account(user, "@taz_de@flipboard.com")

      assert [%{account: @golem, count: 2}, %{account: "@taz_de@flipboard.com", count: 1}] =
               PostRewrites.accounts_for_user(user)

      assert :ok = PostRewrites.delete_rule(user, a.id)
      assert [%{id: ^bid}] = PostRewrites.list_for_account(user, @golem)
    end

    test "compiles for the feed keyed by account", %{user: user} do
      assert PostRewrites.compile_for(user) == %{}
      refute PostRewrites.any?(PostRewrites.compile_for(user))

      {:ok, _} = PostRewrites.create_rule(user, @golem, %{pattern: "^Gepostet in .*$"})

      compiled = PostRewrites.compile_for(user)
      assert [%{pattern: "^Gepostet in .*$"}] = compiled[@golem]
      assert PostRewrites.any?(compiled)
    end

    test "another member can neither move nor delete them", %{user: user, other: other} do
      {:ok, rule} = PostRewrites.create_rule(user, @golem, %{pattern: "a"})

      assert {:error, :not_found} = PostRewrites.delete_rule(other, rule.id)
      assert {:error, :not_found} = PostRewrites.move_rule(other, rule.id, :down)
      assert {:error, :not_found} = PostRewrites.delete_rule(user, "not-a-uuid")
      assert [_still_there] = PostRewrites.list_for_account(user, @golem)
    end

    test "refuses a pattern PCRE cannot compile, an empty one and an over-long one", %{user: user} do
      assert {:error, changeset} = PostRewrites.create_rule(user, @golem, %{pattern: "(a"})
      assert %{pattern: [message]} = errors_on(changeset)
      assert message =~ "not a valid regular expression"
      assert message =~ "missing closing parenthesis"

      assert {:error, changeset} = PostRewrites.create_rule(user, @golem, %{pattern: ""})
      assert %{pattern: [_required]} = errors_on(changeset)

      too_long = String.duplicate("a", PostRewrite.max_pattern() + 1)
      assert {:error, changeset} = PostRewrites.create_rule(user, @golem, %{pattern: too_long})
      assert %{pattern: [_length]} = errors_on(changeset)
    end

    test "an empty replacement is stored as the empty string", %{user: user} do
      {:ok, rule} =
        PostRewrites.create_rule(user, @golem, %{"pattern" => "x", "replacement" => ""})

      assert rule.replacement == ""
    end

    test "refuses an account that is not a handle", %{user: user} do
      assert {:error, :invalid_account} = PostRewrites.create_rule(user, "  ", %{pattern: "a"})
      assert {:error, :invalid_account} = PostRewrites.create_rule(user, "@a b", %{pattern: "a"})
    end

    test "caps the rules per account", %{user: user} do
      for n <- 1..PostRewrites.max_per_account() do
        {:ok, _} = PostRewrites.create_rule(user, @golem, %{pattern: "r#{n}"})
      end

      assert {:error, :too_many_for_account} =
               PostRewrites.create_rule(user, @golem, %{pattern: "one more"})

      assert {:ok, _} = PostRewrites.create_rule(user, "@other@host", %{pattern: "elsewhere"})
    end

    test "rules die with their owner", %{user: user} do
      {:ok, _} = PostRewrites.create_rule(user, @golem, %{pattern: "a"})
      Repo.delete!(%User{id: user.id})

      assert PostRewrites.list_for_account(user, @golem) == []
    end
  end
end
