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

  # A bare in-memory post (body + preloaded tags), enough for the matcher.
  defp post(body, tags \\ []) do
    %Post{body: body, tags: Enum.map(tags, fn {name, slug} -> %Tag{name: name, slug: slug} end)}
  end

  # Compile a hand-written filter list without touching the DB.
  defp compile(filters) do
    tags = for {:tag, p} <- filters, into: %{}, do: {String.downcase(p), p}

    keywords =
      for {:keyword, p, ww} <- filters, do: {p, ContentFilters.compile_pattern(p, ww)}

    %{tags: tags, keywords: keywords}
  end

  defp hidden_by(post, filters), do: ContentFilters.filtered_pattern(post, compile(filters))

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
      assert compiled.tags["crypto"] == "Crypto"
      assert [{"web3*", _re}] = compiled.keywords
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
