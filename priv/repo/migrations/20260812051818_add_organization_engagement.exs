defmodule Vutuv.Repo.Migrations.AddOrganizationEngagement do
  @moduledoc """
  A page can like, bookmark and repost (issue #1336's last loose end).

  The three engagement tables take the same shape the rest of this milestone
  settled on: a nullable `organization_id` beside `user_id` with a CHECK that
  exactly one is set, plus `acting_user_id` for the member who pressed the
  button — recorded, never shown, `nilify_all` so the page's act survives them
  leaving. Same split as `posts.acting_user_id` and `messages.acting_user_id`.

  ## Two unique indexes, not one widened one

  Each table has `unique_index(post_id, user_id)` today. Postgres treats NULLs
  as distinct in a unique index, so once `user_id` is nullable that index stops
  constraining page rows entirely — a page could like the same post a thousand
  times. Each table therefore gets a second unique index on
  `(post_id, organization_id)`, and `Vutuv.Engagement.insert_if_new/3` picks the
  conflict target that matches the party doing the engaging.

  Leaving the old index alone rather than making it partial is deliberate: it
  still does its whole job for member rows, and a partial index would have to be
  matched by a partial conflict target at every call site.

  N-1 safe: the previous release only writes member rows, which satisfy both the
  CHECK and the old index, and every query it runs names `user_id`.
  """
  use Ecto.Migration

  @tables [:post_likes, :post_bookmarks, :post_reposts]

  def up do
    for table <- @tables do
      alter table(table) do
        add(
          :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all)
        )

        add(:acting_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      end

      execute("ALTER TABLE #{table} ALTER COLUMN user_id DROP NOT NULL")

      create(
        constraint(table, :"#{table}_exactly_one_actor",
          check: """
          (CASE WHEN user_id IS NULL THEN 0 ELSE 1 END +
           CASE WHEN organization_id IS NULL THEN 0 ELSE 1 END) = 1
          """
        )
      )

      create(unique_index(table, [:post_id, :organization_id]))
      create(index(table, [:acting_user_id]))
    end
  end

  def down do
    for table <- @tables do
      drop(index(table, [:acting_user_id]))
      drop(unique_index(table, [:post_id, :organization_id]))
      drop(constraint(table, :"#{table}_exactly_one_actor"))

      execute("DELETE FROM #{table} WHERE user_id IS NULL")
      execute("ALTER TABLE #{table} ALTER COLUMN user_id SET NOT NULL")

      alter table(table) do
        remove(:acting_user_id)
        remove(:organization_id)
      end
    end
  end
end
