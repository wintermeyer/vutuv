defmodule Vutuv.Posts.ListTagPostsTest do
  @moduledoc """
  The tag page's "Posts with this tag" list (`Vutuv.Posts.list_tag_posts/1`,
  issue #946). The anonymous public view: a post surfaces only if every
  visitor may read it, so the same visibility gate as `search_public/2`
  applies here.
  """
  use Vutuv.DataCase, async: true
  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias Vutuv.Tags.Tag

  # Per-module unique tag names so async files never share a tags.slug lock
  # (see the test guidelines in .claude/rules/elixir.md).
  ltp_mod_id = :erlang.phash2(__MODULE__, 4_294_967_296)
  @elixir_tag "elixir-#{ltp_mod_id}"
  @ruby_tag "ruby-#{ltp_mod_id}"

  defp author(attrs \\ []), do: insert(:activated_user, attrs)

  defp tag_by_name(name), do: Repo.get_by!(Tag, name: name)

  test "lists public posts carrying the exact tag, newest first" do
    a = author()
    older = create_post!(a, %{body: "First", tags: @elixir_tag})
    newer = create_post!(a, %{body: "Second", tags: @elixir_tag})
    _other = create_post!(a, %{body: "Ruby", tags: @ruby_tag})

    ids = tag_by_name(@elixir_tag) |> Posts.list_tag_posts() |> Enum.map(& &1.id)
    assert ids == [newer.id, older.id]
  end

  test "author and tags are preloaded for rendering" do
    a = author()
    create_post!(a, %{body: "Hello", tags: @elixir_tag})

    assert [post] = Posts.list_tag_posts(tag_by_name(@elixir_tag))
    assert post.user.id == a.id
    assert Enum.map(post.tags, & &1.name) == [@elixir_tag]
  end

  test "hides denied, frozen, unactivated and moderation-hidden posts" do
    a = author()

    create_post!(a, %{
      body: "followers only",
      tags: @elixir_tag,
      denials: [%{"wildcard" => "non_followers"}]
    })

    frozen = create_post!(a, %{body: "frozen", tags: @elixir_tag})

    Repo.update_all(from(p in Posts.Post, where: p.id == ^frozen.id),
      set: [frozen_at: NaiveDateTime.utc_now(:second)]
    )

    unconfirmed = insert(:user, email_confirmed?: false)
    create_post!(unconfirmed, %{body: "spam", tags: @elixir_tag})

    assert Posts.list_tag_posts(tag_by_name(@elixir_tag)) == []
  end

  test "a tag used only in posts (no endorsed members) still returns its posts" do
    a = author()
    post = create_post!(a, %{body: "orphan tag", tags: "obscure"})

    assert [found] = Posts.list_tag_posts(tag_by_name("obscure"))
    assert found.id == post.id
  end

  test "count_tag_posts counts only the visible posts" do
    a = author()
    for i <- 1..3, do: create_post!(a, %{body: "post #{i}", tags: @elixir_tag})

    create_post!(a, %{
      body: "hidden from strangers",
      tags: @elixir_tag,
      denials: [%{"wildcard" => "everyone"}]
    })

    assert Posts.count_tag_posts(tag_by_name(@elixir_tag)) == 3
  end

  test "offset-paginates from the ?page param, newest first" do
    a = author()
    # Oldest -> newest; UUID v7 ids sort by creation, so p5 is newest.
    posts = for i <- 1..5, do: create_post!(a, %{body: "post #{i}", tags: @elixir_tag})
    [_p1, p2, p3, p4, p5] = posts
    tag = tag_by_name(@elixir_tag)

    page1 = Posts.list_tag_posts(tag, %{"page" => "1"}, per_page: 2)
    page2 = Posts.list_tag_posts(tag, %{"page" => "2"}, per_page: 2)
    page3 = Posts.list_tag_posts(tag, %{"page" => "3"}, per_page: 2)

    assert Enum.map(page1, & &1.id) == [p5.id, p4.id]
    assert Enum.map(page2, & &1.id) == [p3.id, p2.id]
    assert length(page3) == 1
  end

  test "an empty tag returns no posts and a zero count" do
    tag = insert(:tag)
    assert Posts.list_tag_posts(tag) == []
    assert Posts.count_tag_posts(tag) == 0
  end
end
