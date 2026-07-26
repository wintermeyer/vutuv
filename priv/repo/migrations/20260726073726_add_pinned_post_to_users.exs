defmodule Vutuv.Repo.Migrations.AddPinnedPostToUsers do
  use Ecto.Migration

  # The post a member showcases at the top of their profile (issue #1110).
  # A single nullable column, not a join table: exactly one post can be pinned
  # at a time, and a column makes that structural instead of a rule the code
  # has to keep. `nilify_all` so deleting the post simply unpins it.
  #
  # The index is what keeps that cascade cheap: without it Postgres scans the
  # whole users table for referencing rows on every post deletion.
  def change do
    alter table(:users) do
      add(:pinned_post_id, references(:posts, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:users, [:pinned_post_id]))
  end
end
