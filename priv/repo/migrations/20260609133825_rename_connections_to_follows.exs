defmodule Vutuv.Repo.Migrations.RenameConnectionsToFollows do
  use Ecto.Migration

  @moduledoc """
  The `connections` table only ever stored a one-directional *follow* edge
  (follower_id → followee_id). The new LinkedIn-style model introduces a real,
  mutual **connection** (its own table, request/accept lifecycle), so the old
  follow table is renamed `follows` to free the name and stop the confusion.

  `memberships.connection_id` is renamed to `follow_id` to match — a membership
  groups one of the author's follow edges. Indexes are renamed to the new
  convention so Ecto's default unique-constraint name keeps matching.
  """

  def up do
    rename(table(:connections), to: table(:follows))
    rename(table(:memberships), :connection_id, to: :follow_id)

    execute("ALTER INDEX IF EXISTS connections_follower_id_index RENAME TO follows_follower_id_index")
    execute("ALTER INDEX IF EXISTS connections_followee_id_index RENAME TO follows_followee_id_index")

    execute(
      "ALTER INDEX IF EXISTS connections_follower_id_followee_id_index RENAME TO follows_follower_id_followee_id_index"
    )

    execute("ALTER INDEX IF EXISTS memberships_connection_id_index RENAME TO memberships_follow_id_index")
  end

  def down do
    execute("ALTER INDEX IF EXISTS memberships_follow_id_index RENAME TO memberships_connection_id_index")

    execute(
      "ALTER INDEX IF EXISTS follows_follower_id_followee_id_index RENAME TO connections_follower_id_followee_id_index"
    )

    execute("ALTER INDEX IF EXISTS follows_followee_id_index RENAME TO connections_followee_id_index")
    execute("ALTER INDEX IF EXISTS follows_follower_id_index RENAME TO connections_follower_id_index")

    rename(table(:memberships), :follow_id, to: :connection_id)
    rename(table(:follows), to: table(:connections))
  end
end
