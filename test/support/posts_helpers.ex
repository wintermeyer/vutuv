defmodule Vutuv.PostsHelpers do
  @moduledoc false

  alias Vutuv.Posts
  alias Vutuv.Posts.PostLike
  alias Vutuv.Repo

  @doc """
  Creates a post for `author`, unwrapping the `{:ok, post}` tuple so tests can
  use the struct directly.
  """
  def create_post!(author, attrs) do
    {:ok, post} = Posts.create_post(author, attrs)
    post
  end

  @doc """
  A page's like on `post` (issue #1410), inserted directly — without the
  publisher-role and DNS-verification pipeline `Posts.like_post/3` sits behind.
  """
  def page_like!(post, page) do
    Repo.insert!(%PostLike{post_id: post.id, organization_id: page.id})
  end
end
