defmodule Vutuv.Repo.Migrations.AddOrganizationFollowerToFollows do
  @moduledoc """
  Issue #1336, the other half of `follows`: an **organization** may follow, not
  only be followed. Same shape as its followee twin — a nullable column beside
  the member one with a CHECK for exactly one — so the table now carries a
  nullable pair on each side and four legal combinations.

  This is the **expand** step and it wires no writer: nothing in the app creates
  such a row yet. That order is deliberate. Widening `posts.user_id` the other
  way round produced eleven silent failures, so here every reader is taught
  about the new row shape *before* one can exist, and the tests insert them
  directly to prove it.

  ## The unique indexes are the subtle part

  `[follower_id, followee_id]` and `[follower_id, followee_organization_id]`
  both stop working for organization followers: those rows leave `follower_id`
  NULL, Postgres treats NULLs as distinct, and the same follow would be
  accepted twice. The two new indexes cover the two organization-follower
  spellings, which is why this migration creates a pair rather than one.

  ## N-1 safe

  The previous release only ever writes member follows, which satisfy the new
  CHECK, and every query it runs against `follows` either scopes to a real
  `follower_id` or joins `users` on it — an organization row matches neither, so
  it stays invisible to that release rather than confusing it. Dropping NOT NULL
  changes no result type, so no cached prepared statement is invalidated.
  """
  use Ecto.Migration

  def up do
    alter table(:follows) do
      add(
        :follower_organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all)
      )
    end

    execute("ALTER TABLE follows ALTER COLUMN follower_id DROP NOT NULL")

    create(
      constraint(:follows, :follows_exactly_one_follower,
        check: """
        (CASE WHEN follower_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN follower_organization_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    create(unique_index(:follows, [:follower_organization_id, :followee_id]))
    create(unique_index(:follows, [:follower_organization_id, :followee_organization_id]))

    # What a page follows, newest first — the page's own Following list and the
    # subquery behind its feed, mirroring `follows_follower_id_inserted_at_...`.
    create(index(:follows, [:follower_organization_id, "inserted_at DESC", "id DESC"]))
  end

  def down do
    drop(index(:follows, [:follower_organization_id, "inserted_at DESC", "id DESC"]))
    drop(unique_index(:follows, [:follower_organization_id, :followee_organization_id]))
    drop(unique_index(:follows, [:follower_organization_id, :followee_id]))
    drop(constraint(:follows, :follows_exactly_one_follower))

    execute("DELETE FROM follows WHERE follower_id IS NULL")
    execute("ALTER TABLE follows ALTER COLUMN follower_id SET NOT NULL")

    alter table(:follows) do
      remove(:follower_organization_id)
    end
  end
end
