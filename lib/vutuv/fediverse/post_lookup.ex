defmodule Vutuv.Fediverse.PostLookup do
  @moduledoc """
  A member here fetched a post from another network by pasting its URL
  (issue #1211).

  Nothing about the act is published: unlike `Vutuv.Fediverse.PostRepost` beside
  it, a lookup says only "somebody wanted to read this here". What the row is
  *for* is retention. A lookup works on any account, followed or not, so the
  cached copy it leaves behind usually has no follower holding it — and
  `purge_unfollowed_remote_posts/0` deletes exactly the copies nobody holds.
  This is the third thing that holds one, beside a reshare (issue #1166) and a
  followed account's boost (issue #1167).

  Like those two it buys no extra time: the copy still expires at its ordinary
  ceiling. What it buys is the right to live out that clock instead of being
  swept the moment the sweep notices nobody follows the author — which, for a
  post looked up precisely because nobody here follows its author, would be
  within the hour.

  The row cascades away with the post and with the member.
  """

  use VutuvWeb, :model

  schema "fediverse_post_lookups" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:remote_post, Vutuv.Fediverse.RemotePost)

    timestamps(updated_at: false)
  end
end
