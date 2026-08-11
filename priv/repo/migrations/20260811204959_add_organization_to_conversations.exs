defmodule Vutuv.Repo.Migrations.AddOrganizationToConversations do
  @moduledoc """
  Issue #1336's last point: somebody can write **to a page**.

  ## The sorted pair does not have to be generalised

  I had this filed for months as the hard one, because `conversations` stores
  its pair sorted (`user_a_id < user_b_id`) so that one unique index can allow
  exactly one conversation per pair. Sorting exists to break a symmetry: with
  two ids from the *same* table, `(a, b)` and `(b, a)` name the same
  conversation and something has to pick a canonical order.

  A member↔page conversation has no such symmetry. The two sides come from
  different tables, so `(user_a_id, organization_id)` is already canonical and
  needs no sorting at all — a second unique index is the whole story. The
  existing `sorted_pair` CHECK is re-created to apply only when `user_b_id` is
  present, which is exactly the case it was written for.

  ## The shape

    * member↔member: `user_a_id` + `user_b_id` (sorted), `organization_id` NULL
    * member↔page:   `user_a_id` = the member, `user_b_id` NULL, `organization_id` set

  So `user_a_id` is always the member, and the CHECK says the other side is
  exactly one of the two kinds.

  The page's side of `conversation_participants` is **one row for the page**,
  not one per publisher — the same model as `organizations.activity_read_at`:
  read means somebody on the team read it, never that everybody did. A row per
  publisher would also have to be invented and retired as roles change, and
  would leave a conversation's read state depending on who still holds a role.

  N-1 safe: the previous release only writes member conversations, which satisfy
  both CHECKs, and every query it runs names `user_a_id`/`user_b_id`.
  """
  use Ecto.Migration

  def up do
    alter table(:conversations) do
      add(
        :organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all)
      )
    end

    execute("ALTER TABLE conversations ALTER COLUMN user_b_id DROP NOT NULL")

    # Only meaningful for a member↔member row; a page conversation has no
    # second user id to order against.
    execute("ALTER TABLE conversations DROP CONSTRAINT sorted_pair")

    execute("""
    ALTER TABLE conversations
      ADD CONSTRAINT sorted_pair
      CHECK (user_b_id IS NULL OR user_a_id < user_b_id)
    """)

    create(
      constraint(:conversations, :conversations_exactly_one_other_side,
        check: """
        (CASE WHEN user_b_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    create(unique_index(:conversations, [:user_a_id, :organization_id]))

    # The page's side of a conversation: one row for the whole team.
    alter table(:conversation_participants) do
      add(
        :organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all)
      )
    end

    execute("ALTER TABLE conversation_participants ALTER COLUMN user_id DROP NOT NULL")

    create(
      constraint(:conversation_participants, :conversation_participants_exactly_one_party,
        check: """
        (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    create(unique_index(:conversation_participants, [:conversation_id, :organization_id]))

    # A message sent in the page's name, with the member who wrote it recorded
    # internally — the same split `posts` uses for authorship (issue #1334).
    alter table(:messages) do
      add(
        :sender_organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all)
      )

      add(:acting_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
    end
  end

  def down do
    alter table(:messages) do
      remove(:acting_user_id)
      remove(:sender_organization_id)
    end

    drop(unique_index(:conversation_participants, [:conversation_id, :organization_id]))
    drop(constraint(:conversation_participants, :conversation_participants_exactly_one_party))
    execute("DELETE FROM conversation_participants WHERE user_id IS NULL")
    execute("ALTER TABLE conversation_participants ALTER COLUMN user_id SET NOT NULL")

    alter table(:conversation_participants) do
      remove(:organization_id)
    end

    drop(unique_index(:conversations, [:user_a_id, :organization_id]))
    drop(constraint(:conversations, :conversations_exactly_one_other_side))

    execute("DELETE FROM conversations WHERE user_b_id IS NULL")
    execute("ALTER TABLE conversations DROP CONSTRAINT sorted_pair")
    execute("ALTER TABLE conversations ADD CONSTRAINT sorted_pair CHECK (user_a_id < user_b_id)")
    execute("ALTER TABLE conversations ALTER COLUMN user_b_id SET NOT NULL")

    alter table(:conversations) do
      remove(:organization_id)
    end
  end
end
