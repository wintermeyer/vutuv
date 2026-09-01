defmodule Vutuv.ContentFiltersTest do
  @moduledoc """
  Personal content filters (issue #940): the keyword/tag matching engine and the
  owner-scoped CRUD.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias Vutuv.ContentFilters
  alias Vutuv.ContentFilters.ContentFilter
  alias Vutuv.Posts.Post
  alias Vutuv.Tags.Tag

  # A bare in-memory post (body + preloaded tags), enough for the matcher. The
  # author is a real row only where a test scopes a rule to an account —
  # everything else never asks who wrote it.
  defp post(body, tags \\ []) do
    %Post{body: body, tags: Enum.map(tags, fn {name, slug} -> %Tag{name: name, slug: slug} end)}
  end

  # Compile a hand-written filter list without touching the DB. Each entry is
  # `{:tag, pattern}` / `{:keyword, pattern, whole_word?}`, optionally followed
  # by the account scope (default: every account).
  defp compile(filters) do
    filters
    |> Enum.map(fn
      {:tag, pattern} ->
        %ContentFilter{kind: :tag, pattern: pattern, account: "*"}

      {:tag, pattern, account} ->
        %ContentFilter{kind: :tag, pattern: pattern, account: account}

      {:keyword, pattern, whole_word} ->
        %ContentFilter{kind: :keyword, pattern: pattern, whole_word: whole_word, account: "*"}

      {:keyword, pattern, whole_word, account} ->
        %ContentFilter{kind: :keyword, pattern: pattern, whole_word: whole_word, account: account}
    end)
    |> ContentFilters.compile()
  end

  defp hidden_by(post, filters), do: ContentFilters.filtered(post, compile(filters))

  describe "keyword matching" do
    test "a whole word matches only that word, not a longer one" do
      filters = [{:keyword, "crypto", true}]

      assert hidden_by(post("I love crypto really"), filters) == "crypto"
      # The classic false-positive trap: "cess" must not hide "success".
      refute hidden_by(post("this is a big success"), [{:keyword, "cess", true}])
      # "cryptocurrency" is a different word, so a whole-word "crypto" leaves it.
      refute hidden_by(post("cryptocurrency is here"), filters)
    end

    test "case-insensitive" do
      assert hidden_by(post("CRYPTO news"), [{:keyword, "crypto", true}]) == "crypto"
    end

    test "a trailing * matches prefixes" do
      filters = [{:keyword, "crypto*", true}]
      assert hidden_by(post("cryptocurrency rocks"), filters) == "crypto*"
      assert hidden_by(post("a cryptobro appears"), filters) == "crypto*"
    end

    test "a leading * matches suffixes" do
      filters = [{:keyword, "*coin", true}]
      assert hidden_by(post("buy bitcoin now"), filters) == "*coin"
      assert hidden_by(post("altcoin season"), filters) == "*coin"
    end

    test "*x* matches anywhere" do
      assert hidden_by(post("a bitcoinmaximalist ranting"), [{:keyword, "*maxi*", true}]) ==
               "*maxi*"
    end

    test "a phrase matches the words adjacent and in order" do
      filters = [{:keyword, "machine learning", true}]
      assert hidden_by(post("I do machine learning daily"), filters) == "machine learning"
      # Reversed order is not the phrase.
      refute hidden_by(post("a learning machine"), filters)
    end

    test "matches a keyword inside markdown emphasis and a hashtag" do
      # `**crypto**` and `#crypto` both surround "crypto" with non-word chars,
      # so a whole-word match still reaches them (no Markdown stripping needed).
      assert hidden_by(post("this is **crypto** stuff"), [{:keyword, "crypto", true}]) == "crypto"
      assert hidden_by(post("gm #crypto folks"), [{:keyword, "crypto", true}]) == "crypto"
    end

    test "a keyword also matches the post's tag names" do
      p = post("a neutral body", [{"Crypto", "crypto"}])
      assert hidden_by(p, [{:keyword, "crypto", true}]) == "crypto"
    end
  end

  describe "tag matching" do
    test "a tag filter hides a post carrying that tag, by name or slug" do
      p = post("nothing to see", [{"Bitcoin", "bitcoin"}])
      assert hidden_by(p, [{:tag, "bitcoin"}]) == "bitcoin"
      # Case-insensitive against the tag name too.
      assert hidden_by(p, [{:tag, "BITCOIN"}]) == "BITCOIN"
    end

    test "a tag filter does not match the same word only in the body" do
      # A Tag entry matches the tag only, not free body text (that's a keyword).
      refute hidden_by(post("I talked about bitcoin today"), [{:tag, "bitcoin"}])
    end
  end

  test "no filters hides nothing" do
    refute hidden_by(post("anything at all"), [])
  end

  describe "owner-scoped CRUD" do
    setup do
      %{user: insert(:user), other: insert(:user)}
    end

    test "create, list newest-first and delete", %{user: user} do
      {:ok, _} = ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "crypto"})
      {:ok, f2} = ContentFilters.create_filter(user, %{"kind" => "tag", "pattern" => "politics"})

      assert [%{pattern: "politics"}, %{pattern: "crypto"}] = ContentFilters.list_for_user(user)

      assert :ok = ContentFilters.delete_filter(user, f2.id)
      assert [%{pattern: "crypto"}] = ContentFilters.list_for_user(user)
    end

    test "a member cannot delete someone else's filter", %{user: user, other: other} do
      {:ok, f} = ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "crypto"})

      assert {:error, :not_found} = ContentFilters.delete_filter(other, f.id)
      assert [%{pattern: "crypto"}] = ContentFilters.list_for_user(user)
    end

    # `DELETE /settings/filters/:id` puts the id straight into a `where`. A
    # tampered non-UUID raised `Ecto.Query.CastError` there, which is a 500 page
    # for a member who edited their own URL — where the house rule is that a
    # malformed id is a miss. `Social.unfollow!/2` spells the reasoning out.
    test "a tampered id is a miss, not a crash", %{user: user} do
      assert {:error, :not_found} = ContentFilters.delete_filter(user, "not-a-uuid")
      assert {:error, :not_found} = ContentFilters.delete_filter(user, "")
    end

    test "the same pattern cannot be added twice", %{user: user} do
      {:ok, _} = ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "crypto"})

      assert {:error, %Ecto.Changeset{}} =
               ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "crypto"})
    end

    test "a wildcard-only pattern is rejected", %{user: user} do
      assert {:error, changeset} =
               ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "***"})

      assert %{pattern: [_]} = errors_on(changeset)
    end

    test "the whole list compiles to the matcher shape", %{user: user} do
      {:ok, _} = ContentFilters.create_filter(user, %{"kind" => "tag", "pattern" => "Crypto"})
      {:ok, _} = ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "web3*"})

      compiled = ContentFilters.compile_for(user)
      assert ContentFilters.any?(compiled)
      assert [%{pattern: "Crypto", tag: "crypto", account: nil}] = compiled.tags
      assert [%{pattern: "web3*", account: nil}] = compiled.keywords
    end

    test "a scoped rule is stored and compiled as such", %{user: user} do
      {:ok, _} =
        ContentFilters.create_filter(user, %{
          "kind" => "keyword",
          "pattern" => "hier besonders häufig",
          "account" => "*@social.heise.de"
        })

      assert [%{account: %Regex{}}] = ContentFilters.compile_for(user).keywords
    end

    test "an empty or wildcard-only account is stored as every account", %{user: user} do
      {:ok, blank} =
        ContentFilters.create_filter(user, %{
          "kind" => "keyword",
          "pattern" => "a",
          "account" => ""
        })

      {:ok, stars} =
        ContentFilters.create_filter(user, %{
          "kind" => "keyword",
          "pattern" => "b",
          "account" => "**"
        })

      assert blank.account == "*"
      assert stars.account == "*"
      assert ContentFilter.every_account?(blank)
      # Nothing names an account, so no post has to be asked who wrote it.
      assert Enum.all?(ContentFilters.compile_for(user).keywords, &(&1.account == nil))
    end

    test "the same word may be muted twice for different accounts", %{user: user} do
      attrs = %{"kind" => "keyword", "pattern" => "hier besonders häufig"}

      {:ok, _} = ContentFilters.create_filter(user, Map.put(attrs, "account", "*heise*"))
      {:ok, _} = ContentFilters.create_filter(user, Map.put(attrs, "account", "*@ard.social"))

      # Only an identical scope is the duplicate the unique index refuses.
      assert {:error, %Ecto.Changeset{}} =
               ContentFilters.create_filter(user, Map.put(attrs, "account", "*heise*"))

      assert length(ContentFilters.list_for_user(user)) == 2
    end
  end

  describe "account scoping" do
    setup do
      # A name that shares nothing with the generated handle, so a scope that
      # matches by name cannot be passing by way of the handle.
      author = insert(:user, first_name: "Zora", last_name: "Blumenkohl")

      %{author: author, post: %Post{post(nil) | user: author, user_id: author.id}}
    end

    test "a rule naming nobody reads every account", %{post: %Post{} = post} do
      assert hidden_by(%Post{post | body: "crypto is here"}, [{:keyword, "crypto", true}]) ==
               "crypto"
    end

    test "a scoped rule holds unless the account matches", %{author: author, post: %Post{} = post} do
      post = %Post{post | body: "crypto is here"}
      mine = [{:keyword, "crypto", true, "@" <> author.username}]

      assert hidden_by(post, mine) == "crypto"
      refute hidden_by(post, [{:keyword, "crypto", true, "@somebody-else"}])
    end

    # The half that makes `*heise*` reach `heise Security`, and the only thing an
    # organization page that never claimed a root handle can be scoped by.
    test "a wildcard scope matches the account's name as well as its handle", %{
      post: %Post{} = post
    } do
      post = %Post{post | body: "crypto is here"}

      assert hidden_by(post, [{:keyword, "crypto", true, "*blumenkohl*"}]) == "crypto"
    end

    test "a tag rule takes a scope too", %{author: author, post: %Post{} = post} do
      post = %Post{post | tags: [%Tag{name: "Bitcoin", slug: "bitcoin"}]}

      assert hidden_by(post, [{:tag, "bitcoin", "@" <> author.username}]) == "bitcoin"
      refute hidden_by(post, [{:tag, "bitcoin", "@somebody-else"}])
    end

    # The safe direction: a rule aimed at somebody in particular must not fold a
    # post from an account nothing can name.
    test "a post with no knowable account never matches a scoped rule" do
      orphan = %Post{post("crypto is here") | user_id: nil, organization_id: nil}

      refute hidden_by(orphan, [{:keyword, "crypto", true, "*heise*"}])
      assert hidden_by(orphan, [{:keyword, "crypto", true}]) == "crypto"
    end
  end

  test "an inserted filter belongs to the user, not a cast user_id" do
    user = insert(:user)
    other = insert(:user)

    {:ok, filter} =
      ContentFilters.create_filter(user, %{
        "kind" => "keyword",
        "pattern" => "crypto",
        "user_id" => other.id
      })

    # user_id is set by the context, never cast, so the injected one is ignored.
    assert filter.user_id == user.id
    assert %ContentFilter{} = filter
  end
end
