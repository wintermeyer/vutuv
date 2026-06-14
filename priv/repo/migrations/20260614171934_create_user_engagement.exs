defmodule Vutuv.Repo.Migrations.CreateUserEngagement do
  use Ecto.Migration

  @moduledoc """
  Liking and bookmarking a *person* (not just a post). Mirrors the
  post-engagement shape: one row per (actor, target) pair, unique per pair so
  the toggle is idempotent, cascading away with either user. The
  `[user_id, inserted_at]` index backs the private "liked people" /
  "bookmarked people" lists on /likes and /bookmarks. A check constraint
  forbids saving yourself.

  Additive (new tables, no column or table touched), so it is N-1 safe: the
  currently deployed release simply never reads or writes these tables. The
  ids are UUID v7 via the repo's binary_id default, like every table created
  after the UUID cutover (see add_blocks).
  """

  def change do
    for table_name <- [:user_likes, :user_bookmarks] do
      create table(table_name) do
        add(:user_id, references(:users, on_delete: :delete_all), null: false)
        add(:target_user_id, references(:users, on_delete: :delete_all), null: false)

        timestamps()
      end

      create(unique_index(table_name, [:user_id, :target_user_id]))
      create(index(table_name, [:user_id, :inserted_at]))
      create(index(table_name, [:target_user_id]))
      create(constraint(table_name, :no_self_save, check: "user_id <> target_user_id"))
    end
  end
end
