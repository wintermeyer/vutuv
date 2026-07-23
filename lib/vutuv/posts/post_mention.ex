defmodule Vutuv.Posts.PostMention do
  @moduledoc """
  One member a post names with `@handle`, resolved at save time.

  The mention itself stays plain text in the body (`Vutuv.Mentions` owns the
  grammar); this row is only the resolved index behind the `"mention"`
  notification kind, reconciled by `Vutuv.Posts` on every post write. Both
  references cascade — the row means nothing once the post or the member is
  gone.
  """

  use VutuvWeb, :model

  schema "post_mentions" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end
end
