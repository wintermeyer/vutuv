defmodule Vutuv.Posts.PostReply do
  @moduledoc false

  use VutuvWeb, :model

  schema "post_replies" do
    # The reply post itself; the row cascades away with it.
    belongs_to(:post, Vutuv.Posts.Post)
    # The post replied to and its author at reply time. Both nilify on
    # deletion, so the reply outlives its parent (see the migration for the
    # banner-state encoding).
    belongs_to(:parent_post, Vutuv.Posts.Post)
    belongs_to(:parent_author, Vutuv.Accounts.User)

    timestamps()
  end
end
