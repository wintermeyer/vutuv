defmodule Vutuv.Fediverse.NoteRepost do
  @moduledoc """
  A member here passed a reply from another network on to their own followers
  (issue #1275) — the sibling of `Vutuv.Fediverse.PostRepost`, keyed to a
  `Vutuv.Fediverse.Note` instead of a cached post.

  Unlike the like markers beside it, this row is **read as well as written**: it
  is a feed source (`Vutuv.Fediverse.feed_remote_reply_reposts/3`), because a
  reshare that reached nobody here would be a button that does nothing on the
  site the member pressed it on. What it carries is the whole entry — the reply
  itself is joined off `note_id`, and `inserted_at` is the entry's time, since
  what is new is the sharing and not the reply.

  No changeset, like every other marker here: both ids come from records the
  caller already resolved, and the write goes through
  `Vutuv.Engagement.insert_if_new/3`, whose row count decides whether an
  `Announce` leaves the building.
  """

  use VutuvWeb, :model

  schema "fediverse_note_reposts" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:note, Vutuv.Fediverse.Note)

    timestamps(updated_at: false)
  end
end
