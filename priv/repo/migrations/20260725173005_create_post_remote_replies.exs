defmodule Vutuv.Repo.Migrations.CreatePostRemoteReplies do
  use Ecto.Migration

  # One vutuv post that answers a reply written on another network (issue
  # #1070). The sidecar to `post_replies`: the answer is still an ordinary reply
  # to the vutuv post underneath (so local threading, notifications, counts and
  # the edit window are untouched), and this row records the *other* thing it
  # answers.
  #
  # Why it carries its own copy of the target instead of reading the note row:
  # a note is collected after six months (`Vutuv.Fediverse.NoteSweeper`) or taken
  # down before that, while the member's own reply lives on. An `Update` or a
  # `Delete(Tombstone)` has to keep reaching the person who was answered, so the
  # delivery address cannot live only in a row that expires. `note_id` nilifies
  # for that reason rather than cascading the answer away.
  def change do
    create table(:post_remote_replies) do
      add(:post_id, references(:posts, on_delete: :delete_all), null: false)
      add(:note_id, references(:fediverse_notes, on_delete: :nilify_all))

      # The durable copy of who was answered and where the answer goes.
      add(:in_reply_to_uri, :string, null: false)
      add(:actor_uri, :string, null: false)
      add(:inbox_uri, :string)
      add(:handle, :string)

      timestamps()
    end

    # One sidecar per answer.
    create(unique_index(:post_remote_replies, [:post_id]))
    # "Which answers belong to this note" — the thread renderer nests each
    # answer under the note it responds to.
    create(index(:post_remote_replies, [:note_id]))
  end
end
