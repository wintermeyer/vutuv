defmodule Vutuv.Repo.Migrations.AddOrganizationFolloweeToFollows do
  @moduledoc """
  Issue #1336, first table: a member may follow an **organization**, so an
  organization that publishes (issue #1334) reaches somebody.

  The shape Stefan chose for this milestone is a nullable `organization_id`
  beside the member column with a CHECK, the same pattern `handles` (#941) and
  `posts` (#1334) already use here — not a shared actor identity. It ships table
  by table and never re-keys a hot one.

  Only the **followee** side gains it. An organization *following* somebody is a
  later step of #1336 and needs its own decisions (whose feed, whose
  notifications), so the follower stays a member and the CHECK says so.

  N-1 safe. The previous release only writes member follows, which still satisfy
  the CHECK, and it only ever reads `follows` filtered by a real followee id or
  joined to `users` — an organization row (`followee_id IS NULL`) matches
  neither. Dropping NOT NULL changes no result type, so no cached prepared
  statement is invalidated.
  """
  use Ecto.Migration

  def up do
    alter table(:follows) do
      add(
        :followee_organization_id,
        references(:organizations, type: :binary_id, on_delete: :delete_all)
      )
    end

    execute("ALTER TABLE follows ALTER COLUMN followee_id DROP NOT NULL")

    create(
      constraint(:follows, :follows_exactly_one_followee,
        check: """
        (CASE WHEN followee_id IS NULL THEN 0 ELSE 1 END +
         CASE WHEN followee_organization_id IS NULL THEN 0 ELSE 1 END) = 1
        """
      )
    )

    # One follow per member per page. The existing
    # `[follower_id, followee_id]` unique index cannot do this job: both of an
    # organization row's spellings leave `followee_id` NULL, and Postgres treats
    # NULLs as distinct, so it would happily take the same follow twice.
    create(unique_index(:follows, [:follower_id, :followee_organization_id]))
    # The organization's own follower count and list read this way round.
    create(index(:follows, [:followee_organization_id]))
  end

  def down do
    drop(index(:follows, [:followee_organization_id]))
    drop(unique_index(:follows, [:follower_id, :followee_organization_id]))
    drop(constraint(:follows, :follows_exactly_one_followee))

    execute("DELETE FROM follows WHERE followee_id IS NULL")
    execute("ALTER TABLE follows ALTER COLUMN followee_id SET NOT NULL")

    alter table(:follows) do
      remove(:followee_organization_id)
    end
  end
end
