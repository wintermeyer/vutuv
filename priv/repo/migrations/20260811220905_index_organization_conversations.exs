defmodule Vutuv.Repo.Migrations.IndexOrganizationConversations do
  @moduledoc """
  The indexes the page side of `conversations` was missing (issue #1336).

  The member side of the inbox query has had a purpose-built index per column
  since it was written — `conversations_user_a_id_last_message_at_index` and its
  `user_b_id` twin. The page side shipped with only
  `unique_index(:conversations, [:user_a_id, :organization_id])`, whose *leading*
  column is `user_a_id`, so nothing in the table could serve

      WHERE organization_id = $1 AND frozen_at IS NULL AND last_message_at IS NOT NULL
      ORDER BY last_message_at DESC

  and Postgres answered it with a sequential scan plus a sort of the whole
  table — sized by the installation's total conversations rather than by the
  page's inbox, on every load of that inbox. (Postgres 17 has no btree skip
  scan, so the composite unique index cannot stand in.)

  `messages.acting_user_id` gets one too. It is `nilify_all`, so deleting a
  member makes Postgres' referential-integrity trigger look for that member's
  rows in `messages` — and with no index that is a full scan of the biggest
  table in this subsystem, on a flow members really do use
  (`Accounts.delete_user/1`). `sender_id` has had an index all along for exactly
  this reason.

  Plain additions, so N-1 safe.
  """
  use Ecto.Migration

  def change do
    create(index(:conversations, [:organization_id, :last_message_at]))
    create(index(:messages, [:acting_user_id]))
  end
end
