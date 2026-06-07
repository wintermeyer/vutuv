defmodule Vutuv.PostsHelpers do
  @moduledoc false

  alias Vutuv.Posts

  @doc """
  Creates a post for `author`, unwrapping the `{:ok, post}` tuple so tests can
  use the struct directly.
  """
  def create_post!(author, attrs) do
    {:ok, post} = Posts.create_post(author, attrs)
    post
  end
end
