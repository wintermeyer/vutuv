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

  defp author(attrs \\ []), do: insert(:activated_user, attrs)

  defp tag_by_name(name), do: Repo.get_by!(Tag, name: name)

  test "lists public posts carrying the exact tag, newest first" do
    a = author()
    older = create_post!(a, %{body: "First", tags: "elixir"})
    newer = create_post!(a, %{body: "Second", tags: "elixir"})
    _other = create_post!(a, %{body: "Ruby", tags: "ruby"})

    ids = tag_by_name("elixir") |> Posts.list_tag_posts() |> Enum.map(& &1.id)
    assert ids == [newer.id, older.id]
  end

  test "author and tags are preloaded for rendering" do
    a = author()
    create_post!(a, %{body: "Hello", tags: "elixir"})

    assert [post] = Posts.list_tag_posts(tag_by_name("elixir"))
    assert post.user.id == a.id
    assert Enum.map(post.tags, & &1.name) == ["elixir"]
  end

  test "hides denied, frozen, unactivated and moderation-hidden posts" do
    a = author()

    create_post!(a, %{
      body: "followers only",
      tags: "elixir",
      denials: [%{"wildcard" => "non_followers"}]
    })

    frozen = create_post!(a, %{body: "frozen", tags: "elixir"})

    Repo.update_all(from(p in Posts.Post, where: p.id == ^frozen.id),
      set: [frozen_at: NaiveDateTime.utc_now(:second)]
    )

    unconfirmed = insert(:user, email_confirmed?: false)
    create_post!(unconfirmed, %{body: "spam", tags: "elixir"})

    assert Posts.list_tag_posts(tag_by_name("elixir")) == []
  end

  test "a tag used only in posts (no endorsed members) still returns its posts" do
    a = author()
    post = create_post!(a, %{body: "orphan tag", tags: "obscure"})

    assert [found] = Posts.list_tag_posts(tag_by_name("obscure"))
    assert found.id == post.id
  end

  test "respects the limit" do
    a = author()
    for i <- 1..4, do: create_post!(a, %{body: "post #{i}", tags: "elixir"})

    assert length(Posts.list_tag_posts(tag_by_name("elixir"), limit: 2)) == 2
  end

  test "an empty tag returns no posts" do
    tag = insert(:tag, name: "lonely", slug: "lonely")
    assert Posts.list_tag_posts(tag) == []
  end
end
