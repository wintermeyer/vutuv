defmodule Vutuv.Fediverse.NoteLike do
  @moduledoc """
  A member here liked a reply that came from another network (issue #1270) —
  the sibling of `Vutuv.Fediverse.PostLike`, one step further down the
  conversation.

  Everything that module says applies unchanged, and is worth repeating in the
  one place somebody reading this table will look. The row is a **marker, not a
  tally**: what the author's server counts is the `Like` activity we delivered,
  and this says only "this member, this reply", so the heart comes back painted
  on the next page load. Nothing here is public and nothing here is a number —
  vutuv does not know how many people liked a reply over there, and a count
  assembled from the likes that happened to pass through this installation
  would read as the real one while being a fraction of it.

  No changeset, for the same reason: nothing here is user-supplied (both ids
  come from records the caller already resolved) and the write goes through
  `Vutuv.Engagement.insert_if_new/3`, whose row count is what decides whether an
  activity leaves the building.

  It cascades away with the cached reply, which is correct rather than lossy:
  our copy is a six-month cache, the like on the author's server is not ours to
  keep alive.
  """

  use VutuvWeb, :model

  schema "fediverse_note_likes" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:note, Vutuv.Fediverse.Note)

    timestamps(updated_at: false)
  end
end
