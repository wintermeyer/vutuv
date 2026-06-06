defmodule Vutuv.Posts.PostBookmark do
  @moduledoc false

  use VutuvWeb, :model

  schema "post_bookmarks" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end
end
