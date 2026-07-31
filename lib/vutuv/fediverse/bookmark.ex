defmodule Vutuv.Fediverse.Bookmark do
  @moduledoc """
  A member saved something from another network for themselves (issue #1276) —
  a cached post by a followed account, or a reply that arrived under a vutuv
  post.

  **One schema for both kinds**, where the like and reshare markers have one
  each. The reason is in the migration and worth repeating: those two are read
  by queries that join their own subject and its own audience rules, and the
  reshare is a feed source; a bookmark federates nothing, is addressed to
  nobody, and is only ever read as "what did this member save", which wants the
  two kinds in one list rather than two. Exactly one of `remote_post_id` /
  `note_id` is set, and a check constraint says so.

  It is also the one act on these cards that asks nothing of the member's
  Fediverse standing: no actor is needed because nothing is signed and nothing
  leaves the building.

  No changeset, like every marker here — both ids come from records the caller
  already resolved, and the write goes through
  `Vutuv.Engagement.insert_if_new/3`.
  """

  use VutuvWeb, :model

  schema "fediverse_bookmarks" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:remote_post, Vutuv.Fediverse.RemotePost)
    belongs_to(:note, Vutuv.Fediverse.Note)

    timestamps(updated_at: false)
  end
end
