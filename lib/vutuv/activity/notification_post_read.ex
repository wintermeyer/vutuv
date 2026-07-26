defmodule Vutuv.Activity.NotificationPostRead do
  @moduledoc """
  One member has seen one post — the per-item read mark behind
  `Vutuv.Activity.mark_post_seen/2`.

  Written when the member answers, likes, bookmarks or reposts the post, since
  none of those happen to a post nobody looked at. The unread notification tally
  then skips every event whose subject is that post.
  """

  use VutuvWeb, :model

  schema "notification_post_reads" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:post, Vutuv.Posts.Post)

    timestamps()
  end
end
