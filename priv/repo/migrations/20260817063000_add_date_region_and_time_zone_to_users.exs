defmodule Vutuv.Repo.Migrations.AddDateRegionAndTimeZoneToUsers do
  use Ecto.Migration

  # Issue #1502: the member's own date shape and clock. Two nullable columns
  # with no DB default, the shape every `Vutuv.Prefs` knob has — nil means
  # "inherit the installation default", which is what tells an untouched
  # account apart from one that deliberately picked the default value.
  #
  # Both are bounded by their own validations rather than by the column: a date
  # region is one of four keys, and an IANA zone identifier is well under 60
  # characters (`America/Argentina/Buenos_Aires`, the longest one offered, is
  # 30), so varchar(255) is generous either way.
  def change do
    alter table(:users) do
      add(:date_region, :string)
      add(:time_zone, :string)
    end
  end
end
