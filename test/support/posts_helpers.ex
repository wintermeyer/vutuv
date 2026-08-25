defmodule Vutuv.PostsHelpers do
  @moduledoc false

  import Ecto.Query

  alias Vutuv.Posts
  alias Vutuv.Posts.Post
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
  Moves `post` `seconds` into the past and hands back the updated struct.

  Every timestamp the feed compares has **second** precision, so a test whose
  posts, follows and spans all happen in one second is deciding ties rather than
  rules — anything asserting on order, on a cursor, or on a follow's span
  (issue #1673) has to place its posts by hand.
  """
  def backdate_post!(post, seconds) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -seconds)
    Repo.update_all(from(p in Post, where: p.id == ^post.id), set: [inserted_at: at])
    %{post | inserted_at: at}
  end

  @doc """
  A page's like on `post` (issue #1410), inserted directly — without the
  publisher-role and DNS-verification pipeline `Posts.like_post/3` sits behind.
  """
  def page_like!(post, page) do
    Repo.insert!(%PostLike{post_id: post.id, organization_id: page.id})
  end
end
