defmodule Vutuv.Posts.PostSearchTest do
  @moduledoc """
  Full-text search over posts (`Vutuv.Posts.search_public/2`). Only posts
  every visitor may read can surface: any denial, a frozen post, an
  unactivated or moderation-hidden author all exclude one — search results
  are shown to logged-out visitors too, so the filter must be the strictest
  view there is.
  """
  use Vutuv.DataCase, async: true
  import Vutuv.PostsHelpers

  alias Vutuv.Posts

  defp author(attrs \\ []), do: insert(:activated_user, attrs)

  test "finds public posts by body words, any order, author preloaded" do
    a = author()
    post = create_post!(a, %{body: "Elixir conference in Koblenz next spring"})
    _miss = create_post!(a, %{body: "Nothing about that city here"})

    assert [found] = Posts.search_public("koblenz conference")
    assert found.id == post.id
    assert found.user.id == a.id
  end

  test "any denial hides a post from search" do
    a = author()

    create_post!(a, %{
      body: "Koblenz meetup for followers only",
      denials: [%{"wildcard" => "non_followers"}]
    })

    assert Posts.search_public("koblenz") == []
  end

  test "a frozen post is hidden" do
    a = author()
    post = create_post!(a, %{body: "Koblenz greetings"})

    Repo.update_all(from(p in Posts.Post, where: p.id == ^post.id),
      set: [frozen_at: NaiveDateTime.utc_now(:second)]
    )

    assert Posts.search_public("koblenz") == []
  end

  test "posts by unactivated authors are hidden" do
    a = insert(:user, email_confirmed?: false)
    create_post!(a, %{body: "Koblenz spam from an unverified account"})

    assert Posts.search_public("koblenz") == []
  end

  test "posts by moderation-hidden authors are hidden" do
    a = author()
    create_post!(a, %{body: "Koblenz post by a suspended member"})

    until = NaiveDateTime.add(NaiveDateTime.utc_now(:second), 7 * 24 * 3600)

    Repo.update_all(from(u in Vutuv.Accounts.User, where: u.id == ^a.id),
      set: [suspended_until: until]
    )

    assert Posts.search_public("koblenz") == []
  end

  test "results are capped" do
    a = author()
    for i <- 1..5, do: create_post!(a, %{body: "Koblenz post number #{i}"})

    assert length(Posts.search_public("koblenz", limit: 3)) == 3
  end

  test "blank and operator-garbage queries return nothing instead of crashing" do
    a = author()
    create_post!(a, %{body: "Koblenz"})

    assert Posts.search_public("") == []
    assert Posts.search_public("   ") == []
    # websearch_to_tsquery treats operators as literal text - must not raise.
    assert is_list(Posts.search_public(~s{"unbalanced & | ! (}))
  end

  describe "tag: filter (issue #946)" do
    test "a bare tag filter lists posts carrying that tag, newest first" do
      a = author()
      older = create_post!(a, %{body: "First elixir note", tags: "elixir"})
      newer = create_post!(a, %{body: "Second elixir note", tags: "elixir"})
      _other = create_post!(a, %{body: "A ruby note", tags: "ruby"})

      # Empty body + a tag: filter is a pure tag listing.
      ids = Posts.search_public("", tag: "elixir") |> Enum.map(& &1.id)
      assert ids == [newer.id, older.id]
    end

    test "combines with body words (AND)" do
      a = author()
      match = create_post!(a, %{body: "Koblenz elixir meetup", tags: "elixir"})
      _wrong_body = create_post!(a, %{body: "Berlin elixir meetup", tags: "elixir"})
      _wrong_tag = create_post!(a, %{body: "Koblenz ruby meetup", tags: "ruby"})

      assert [found] = Posts.search_public("koblenz", tag: "elixir")
      assert found.id == match.id
    end

    test "substring matches the tag name, exact does not" do
      a = author()
      post = create_post!(a, %{body: "phpstorm tips", tags: "phpstorm"})

      assert [found] = Posts.search_public("", tag: "php")
      assert found.id == post.id
      assert Posts.search_public("", tag: "php", exact: true) == []
      assert [exact] = Posts.search_public("", tag: "phpstorm", exact: true)
      assert exact.id == post.id
    end

    test "a tag filter still hides posts a visitor may not read" do
      a = author()

      create_post!(a, %{
        body: "elixir for followers",
        tags: "elixir",
        denials: [%{"wildcard" => "non_followers"}]
      })

      assert Posts.search_public("", tag: "elixir") == []
    end
  end
end
