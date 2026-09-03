defmodule Vutuv.Repo.Migrations.AddFeedReadAtToUsers do
  use Ecto.Migration

  # How far the member has read their feed — the marker the "Feed" nav badge
  # counts arrivals against, the same job `notifications_read_at` does for the
  # bell. `Vutuv.Posts.mark_feed_read/1` writes it at every feed mount and
  # whenever the reader reveals what waited behind the pill.
  #
  # `now()` rather than NULL, at insert and for every existing row: a NULL
  # marker would mean "never read the feed", so every member alive would open
  # their next page to a badge counting their whole feed. Starting everybody at
  # the deploy means the badge only ever speaks about posts that arrived after
  # it shipped, which is what a "new since you last looked" figure has to
  # promise. A fresh sign-up gets the same treatment from the default.
  #
  # A plain add with a default, so the currently deployed release keeps working
  # unchanged (N-1): it never mentions the column and its inserts fill it.
  def change do
    alter table(:users) do
      add(:feed_read_at, :naive_datetime, null: false, default: fragment("now()"))
    end
  end
end
