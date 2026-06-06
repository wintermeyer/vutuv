defmodule Vutuv.Posts.PostLike do
  @moduledoc false

  use VutuvWeb, :model

  schema "post_likes" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end
end
