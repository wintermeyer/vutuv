defmodule Vutuv.Repo.Migrations.AddFediverseDirectMessages do
  @moduledoc """
  A conversation can have an **account on another network** on the other side.

  The third party kind follows the page shape (`20260811204959`) exactly:
  `user_a_id` is always the member, and a CHECK says the other side is exactly
  one of the three columns. Sorting still applies only to the member↔member
  pair, whose two ids come from the same table.

      member <-> member: user_a_id + user_b_id (sorted)
      member <-> page:   user_a_id + organization_id
      member <-> remote: user_a_id + remote_account_id

  Two things this shape needs that the page did not.

  **`initiator_id` becomes nullable.** A remote account can open a conversation,
  and it is not a row in `users`. NULL therefore means "the remote side started
  it", which is also what lets the member accept the request: every rule that
  reads `initiator_id != me` has to treat NULL as "not me" rather than as
  unknown, since `NULL != <id>` is NULL and not true. A CHECK keeps the column
  from being empty on a conversation that has no remote side.

  **The message keeps a pointer to what it already is elsewhere.** A private
  answer under a post is a `fediverse_notes` row, and a sent one is a
  `fediverse_private_messages` row; both keep rendering under the post exactly
  as before. The conversation's message links to whichever it came from, so the
  two views can link to each other, and both links are `ON DELETE SET NULL`:
  a note expires after 183 days (`note_retention_days/0`) while the
  conversation is the member's own mail and stays. `remote_object_uri` carries
  the incoming activity's AP id so a redelivery cannot store a second copy —
  the same job `fediverse_notes.object_uri` does on the post side, and the one
  a message without a note (a plain DM) has nowhere else to record.

  N-1 safe: every column is an addition, the dropped NOT NULL only widens what
  is accepted, and the previous release writes conversations whose other side
  is a member or a page, which satisfies the widened CHECK.
  """
  use Ecto.Migration

  def up do
    alter table(:conversations) do
      add(
        :remote_account_id,
        references(:fediverse_remote_accounts, type: :binary_id, on_delete: :delete_all)
      )
    end

    execute("ALTER TABLE conversations ALTER COLUMN initiator_id DROP NOT NULL")

    execute("ALTER TABLE conversations DROP CONSTRAINT conversations_exactly_one_other_side")

    execute("""
    ALTER TABLE conversations
      ADD CONSTRAINT conversations_exactly_one_other_side
      CHECK ((CASE WHEN user_b_id IS NULL THEN 0 ELSE 1 END +
              CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END +
              CASE WHEN remote_account_id IS NULL THEN 0 ELSE 1 END) = 1)
    """)

    # Only a conversation with a remote side may lack a local initiator.
    execute("""
    ALTER TABLE conversations
      ADD CONSTRAINT conversations_initiator_present
      CHECK (initiator_id IS NOT NULL OR remote_account_id IS NOT NULL)
    """)

    create(unique_index(:conversations, [:user_a_id, :remote_account_id]))
    create(index(:conversations, [:remote_account_id]))

    alter table(:messages) do
      # Who wrote it, when that was not somebody here. Nilified rather than
      # cascaded, so a *single* account row going — the hourly sweeper, a
      # `Delete` from its own server — leaves the member's record of what was
      # said standing. An operator blocking the whole server is the deliberate
      # exception: `purge_instance/1` takes every row from that host and the
      # conversation cascades away with the account.
      add(
        :sender_remote_account_id,
        references(:fediverse_remote_accounts, type: :binary_id, on_delete: :nilify_all)
      )

      add(:note_id, references(:fediverse_notes, type: :binary_id, on_delete: :nilify_all))

      add(
        :private_message_id,
        references(:fediverse_private_messages, type: :binary_id, on_delete: :nilify_all)
      )

      add(:remote_object_uri, :text)
    end

    create(unique_index(:messages, [:remote_object_uri]))
    create(unique_index(:messages, [:note_id]))
    create(unique_index(:messages, [:private_message_id]))

    # A message is one thing said once, so it is the second view of at most one
    # of the two stores. A row naming both would draw two "to the post" links
    # at two different posts, with nothing to say which one is right.
    execute("""
    ALTER TABLE messages
      ADD CONSTRAINT messages_at_most_one_source
      CHECK ((CASE WHEN note_id IS NULL THEN 0 ELSE 1 END +
              CASE WHEN private_message_id IS NULL THEN 0 ELSE 1 END) <= 1)
    """)
  end

  def down do
    execute("ALTER TABLE messages DROP CONSTRAINT messages_at_most_one_source")
    drop(unique_index(:messages, [:private_message_id]))
    drop(unique_index(:messages, [:note_id]))
    drop(unique_index(:messages, [:remote_object_uri]))

    alter table(:messages) do
      remove(:remote_object_uri)
      remove(:private_message_id)
      remove(:note_id)
      remove(:sender_remote_account_id)
    end

    drop(index(:conversations, [:remote_account_id]))
    drop(unique_index(:conversations, [:user_a_id, :remote_account_id]))

    execute("DELETE FROM conversations WHERE remote_account_id IS NOT NULL")
    execute("ALTER TABLE conversations DROP CONSTRAINT conversations_initiator_present")
    execute("ALTER TABLE conversations DROP CONSTRAINT conversations_exactly_one_other_side")

    execute("""
    ALTER TABLE conversations
      ADD CONSTRAINT conversations_exactly_one_other_side
      CHECK ((CASE WHEN user_b_id IS NULL THEN 0 ELSE 1 END +
              CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END) = 1)
    """)

    execute("ALTER TABLE conversations ALTER COLUMN initiator_id SET NOT NULL")

    alter table(:conversations) do
      remove(:remote_account_id)
    end
  end
end
