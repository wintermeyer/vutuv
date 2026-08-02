defmodule Vutuv.Repo.Migrations.AddLikeAttributionPrefToUsers do
  use Ecto.Migration

  # Issue #1233: a post permalink now names the members who liked it, so every
  # member gets a switch over their own likes (`Vutuv.Prefs`, group :privacy).
  #
  # Nullable with **no** DB default, like every other pref column: NULL means
  # "inherit the installation default" (/admin/preferences), and the shipped
  # default lives only in the registry — so "never touched" stays
  # distinguishable from "chose the shipped value". A plain nullable column is
  # an additive, N-1-compatible change: the release currently serving traffic
  # never reads it.
  def change do
    alter table(:users) do
      add(:like_attribution?, :boolean)
    end
  end
end
