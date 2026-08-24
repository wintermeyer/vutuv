defmodule Vutuv.Repo.Migrations.AddFeedTabTickerPrefs do
  use Ecto.Migration

  @moduledoc """
  The feed's tab ticker: when something lands on the source tab a member is
  *not* looking at, the bar quotes its first words for a few seconds instead of
  only growing a dot.

  Two knobs, both `Vutuv.Prefs` (group `:feed_tabs`): `feed_tab_ticker?` turns
  the quote off again and leaves the plain dot, and `feed_tab_ticker_seconds`
  says how long the quote stands. Nullable with **no** DB default, like every
  other pref column: NULL means "inherit the installation default", and the
  shipped values (on, 8 seconds) live only in the registry.

  N-1 safe: pure nullable additions the deployed release never reads.
  """

  def change do
    alter table(:users) do
      add(:feed_tab_ticker?, :boolean)
      add(:feed_tab_ticker_seconds, :integer)
    end
  end
end
