defmodule Vutuv.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations) do
      # The unordered user pair, stored sorted (user_a_id < user_b_id) so the
      # unique index guarantees exactly one 1:1 conversation per pair without
      # application-level locking.
      add(:user_a_id, references(:users, on_delete: :delete_all), null: false)
      add(:user_b_id, references(:users, on_delete: :delete_all), null: false)
      # Who opened the conversation — the "message request" sender while pending.
      add(:initiator_id, references(:users, on_delete: :delete_all), null: false)
      # pending → accepted | declined. Declined is silent and permanent: the
      # recipient never sees the conversation again and sends into it are
      # dropped without signalling the sender.
      add(:status, :string, null: false, default: "pending")
      # Denormalized newest-message time for sidebar ordering; bumped in the
      # same transaction as each message insert.
      add(:last_message_at, :naive_datetime)

      timestamps()
    end

    create(unique_index(:conversations, [:user_a_id, :user_b_id]))
    create(constraint(:conversations, :sorted_pair, check: "user_a_id < user_b_id"))
    # The sidebar lists a user's conversations newest-activity-first.
    create(index(:conversations, [:user_a_id, :last_message_at]))
    create(index(:conversations, [:user_b_id, :last_message_at]))

    # One row per (conversation, user): read state and the unread-email
    # debounce marker live here. Redundant with the pair columns for 1:1, but
    # it is what the unread/badge/email queries scan by user, and the table a
    # future group feature would reuse.
    create table(:conversation_participants) do
      add(:conversation_id, references(:conversations, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      # null = never opened the conversation.
      add(:last_read_at, :naive_datetime)
      # When the unread-notification email for the current unread burst went
      # out; nulled on read so the next burst may email again.
      add(:notified_at, :naive_datetime)

      timestamps()
    end

    create(unique_index(:conversation_participants, [:conversation_id, :user_id]))
    create(index(:conversation_participants, [:user_id]))

    create table(:messages) do
      add(:conversation_id, references(:conversations, on_delete: :delete_all), null: false)
      # Nullable + nilify: a deleted sender's messages survive for the other
      # participant (rendered as a deleted account), while deleting either
      # participant's account cascades the whole conversation away via the
      # pair FKs above.
      add(:sender_id, references(:users, on_delete: :nilify_all))
      add(:body, :text, null: false)

      timestamps()
    end

    # Keyset pagination reads newest-first per conversation; UUID v7 ids sort
    # by creation time, so id is a valid tiebreaker.
    create(index(:messages, [:conversation_id, :inserted_at, :id]))
  end
end
