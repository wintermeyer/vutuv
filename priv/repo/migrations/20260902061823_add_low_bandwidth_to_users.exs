defmodule Vutuv.Repo.Migrations.AddLowBandwidthToUsers do
  use Ecto.Migration

  # One nullable column, no default: nil has to stay distinguishable from a
  # member who deliberately chose "off", because nil is what inherits the
  # installation default (Vutuv.Prefs). Plain addition, so it is N-1 safe —
  # the running release never reads or writes it.
  def change do
    alter table(:users) do
      add(:low_bandwidth?, :boolean)
    end
  end
end
