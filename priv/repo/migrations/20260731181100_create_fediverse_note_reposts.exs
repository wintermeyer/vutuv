defmodule Vutuv.Repo.Migrations.CreateFediverseNoteReposts do
  use Ecto.Migration

  @moduledoc """
  A member here passed a **reply** from another network on to their own
  followers (issue #1275) — the sibling of `fediverse_post_reposts`, one table
  further down the conversation, exactly as `fediverse_note_likes` is of
  `fediverse_post_likes`.

  Unlike the like marker beside it this row is **read**, not only written: it is
  a feed source (`Vutuv.Fediverse.feed_remote_reply_reposts/3`), which is how
  somebody who follows nobody out there meets the reply at all — through
  somebody here vouching for it. Hence the second index: the feed asks "what
  have the people I follow reshared, newest first", which is a scan by user and
  time, not by note.

  It cascades away with the cached reply, which is correct rather than lossy:
  our copy is a six-month cache and the `Announce` on the resharer's followers'
  servers is not ours to keep alive.
  """

  def change do
    create table(:fediverse_note_reposts) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:note_id, references(:fediverse_notes, on_delete: :delete_all), null: false)

      timestamps(updated_at: false)
    end

    # The pair is the identity: resharing twice is the same reshare.
    create(unique_index(:fediverse_note_reposts, [:user_id, :note_id]))
    # The cascade's own index, so a note delete does not scan this table.
    create(index(:fediverse_note_reposts, [:note_id]))
    # The feed's own read: "the reshares of the people I follow, newest first".
    create(index(:fediverse_note_reposts, [:user_id, :inserted_at]))
  end
end
