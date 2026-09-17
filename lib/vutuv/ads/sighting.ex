defmodule Vutuv.Ads.Sighting do
  @moduledoc """
  A booked ad a member has seen: one row per member and ad, written by
  `Vutuv.Ads.record_sighting/3`. `first_seen_at` stays, `last_seen_at` and
  `times_seen` move with every further sighting. The house ad leaves no row.
  """

  use VutuvWeb, :model

  schema "ad_sightings" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:ad, Vutuv.Ads.Ad)

    field(:first_seen_at, :utc_datetime)
    field(:last_seen_at, :utc_datetime)
    field(:times_seen, :integer, default: 1)
  end
end
