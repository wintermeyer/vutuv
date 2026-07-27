defmodule Vutuv.Fediverse.PostLike do
  @moduledoc """
  A member here liked a post from an account on another network (issue #1164).

  The row is a **marker, not a tally**. What the author's server counts is the
  `Like` activity we delivered; this says only "this member, this post", so the
  heart can come back painted on the next page load. Nothing here is public and
  nothing here is a number: vutuv does not know how many people liked a post
  over there, and a count assembled from the likes that happened to pass
  through this installation would read as the real one while being a fraction
  of it.

  There is deliberately **no changeset**: nothing here is user-supplied (both
  ids come from records the caller already resolved), and the write goes through
  `Vutuv.Engagement.insert_if_new/3` — the join-row kernel the post and member
  like/bookmark toggles share — whose row count answers the one question that
  matters: whether this request is what created the like, and therefore whether
  an activity should leave the building.

  It cascades away with the cached post, which is correct rather than lossy:
  our copy of the post is a six-month cache, the like on the author's server is
  not ours to keep alive. A member who likes the same post again after that
  sends a duplicate `Like`, which every implementation treats as a no-op.
  """

  use VutuvWeb, :model

  schema "fediverse_post_likes" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:remote_post, Vutuv.Fediverse.RemotePost)

    timestamps(updated_at: false)
  end
end
