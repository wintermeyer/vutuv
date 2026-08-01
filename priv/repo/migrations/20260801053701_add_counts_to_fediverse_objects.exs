defmodule Vutuv.Repo.Migrations.AddCountsToFediverseObjects do
  use Ecto.Migration

  # What the origin server says about its own object (issue #1283): how many
  # people there liked it and how many passed it on. Plain additions, so this is
  # N-1 compatible — the release currently serving traffic never reads them.
  #
  # Nullable on purpose. `likes` and `shares` are MAY in ActivityPub §5.7/§5.8
  # and some software does not serve them at all, so "we have not been told" has
  # to be distinguishable from "nobody liked it": a zero is a claim, and it is
  # not ours to make on somebody else's behalf.
  #
  # `counts_etag` is a **text** column: it holds a string a stranger's server
  # wrote, no changeset guards it (nothing user-facing writes this row), and a
  # varchar(255) would turn a long ETag into a 22001 on the refresh path — the
  # `inbox_uri` lesson from issue #1102.
  def change do
    for table <- [:fediverse_posts, :fediverse_notes] do
      alter table(table) do
        add(:likes_count, :integer)
        add(:shares_count, :integer)
        add(:counts_checked_at, :utc_datetime)
        add(:counts_etag, :text)
        # Consecutive failed asks. Drives the per-object exponential backoff and
        # drops the object off the ladder after a few strikes, so a server having
        # a bad day never sees us return every quarter of an hour.
        add(:counts_failures, :integer, null: false, default: 0)
      end

      # The refresher takes the least recently asked rows first, nulls first.
      create(index(table, [:counts_checked_at]))
    end
  end
end
