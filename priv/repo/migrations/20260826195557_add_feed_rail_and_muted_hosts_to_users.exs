defmodule Vutuv.Repo.Migrations.AddFeedRailAndMutedHostsToUsers do
  use Ecto.Migration

  # Two additive columns for the feed's filter band, both nullable and both
  # read by the new release only — N-1 safe, nothing existing looks at them.
  #
  # `feed_muted_hosts` is the server-level twin of `fediverse_follows.muted`:
  # a member can switch off a whole instance without touching each account on
  # it. A short array on the member beats a join table here — the list is a
  # handful of hostnames, it is read once per feed page beside the member row
  # that is already loaded, and it never needs its own identity.
  #
  # `feed_rail` holds how the member arranged the band: the block order, what
  # they collapsed to a single line and what they removed altogether. A map
  # rather than three columns, because it is one decision ("my sidebar looks
  # like this") that the panel writes as a whole.
  def change do
    alter table(:users) do
      add(:feed_muted_hosts, {:array, :string})
      add(:feed_rail, :map)
    end
  end
end
