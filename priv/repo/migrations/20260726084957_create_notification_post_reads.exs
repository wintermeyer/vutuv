defmodule Vutuv.Repo.Migrations.CreateNotificationPostReads do
  use Ecto.Migration

  # "This member has demonstrably seen that post." Written when they answer,
  # like, bookmark or repost it — four actions nobody performs on a post they
  # have not read.
  #
  # The notifications feed is derived at read time and its only stored state is
  # the single `users.notifications_read_at` marker, which can say "everything
  # up to here" and nothing else. This table is the per-item exception: it lets
  # the unread tally skip the events the member has already dealt with out in
  # the feed, without moving the marker past everything else.
  #
  # One row per (member, post); the pair is unique because the four actions are
  # idempotent toggles and each of them may fire more than once. Both sides
  # cascade — a deleted post or member leaves nothing behind.
  def change do
    create table(:notification_post_reads) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:post_id, references(:posts, on_delete: :delete_all), null: false)

      timestamps()
    end

    create(unique_index(:notification_post_reads, [:user_id, :post_id]))
  end
end
