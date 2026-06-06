defmodule Vutuv.Repo.Migrations.CreatePostEngagement do
  use Ecto.Migration

  def change do
    # Likes, bookmarks and reposts share one shape: a (post, user) pair,
    # unique per pair (toggles are idempotent), cascading away with either
    # side. Counters are counted live from these rows — no counter caches to
    # drift. The [user_id, inserted_at] indexes back the "my likes" / "my
    # bookmarks" pages and the reposts-by-followees feed leg.
    for table_name <- [:post_likes, :post_bookmarks, :post_reposts] do
      create table(table_name) do
        add(:post_id, references(:posts, on_delete: :delete_all), null: false)
        add(:user_id, references(:users, on_delete: :delete_all), null: false)

        timestamps()
      end

      create(unique_index(table_name, [:post_id, :user_id]))
      create(index(table_name, [:user_id, :inserted_at]))
    end
  end
end
