defmodule Vutuv.Posts.PostBookmark do
  @moduledoc false

  use VutuvWeb, :model

  schema "post_bookmarks" do
    belongs_to(:post, Vutuv.Posts.Post)
    # Exactly one of these two is set (CHECK): a member's act, or a page's
    # (issue #1336). `acting_user` records which publisher pressed the button -
    # kept for accountability, never shown, `nilify_all` so the page's act
    # survives them leaving. Same split as `posts` and `messages`.
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:organization, Vutuv.Organizations.Organization)
    belongs_to(:acting_user, Vutuv.Accounts.User)

    timestamps()
  end
end
