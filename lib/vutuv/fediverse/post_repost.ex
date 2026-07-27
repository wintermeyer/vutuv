defmodule Vutuv.Fediverse.PostRepost do
  @moduledoc """
  A member here shared a post from another network onward (issue #1166).

  Unlike the like beside it (`Vutuv.Fediverse.PostLike`, a private marker), this
  is a **publishing act**: the post appears in the feeds of everyone who follows
  the reposter here, on their profile, and — as an `Announce` — in the feeds of
  their Fediverse followers. It is the one way a member who follows nobody on
  another network meets that network's content at all.

  It is also the one thing that keeps a cached post alive past its ceiling. Our
  copies expire after six months because a cache with no end is not a cache, but
  a copy somebody has vouched for by resharing it is exactly the copy that
  should not vanish under the people reading it. So the retention sweep skips a
  reposted post and a slow re-fetch takes over: still published pushes the
  ceiling out, gone upstream deletes the copy and these rows with it. A repost
  never keeps alive what its author has already deleted.

  The row cascades away with the cached post for that reason, and with the
  member. What stands on other servers is the `Announce`, which the withdrawal
  path undoes.
  """

  use VutuvWeb, :model

  schema "fediverse_post_reposts" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:remote_post, Vutuv.Fediverse.RemotePost)

    timestamps(updated_at: false)
  end
end
