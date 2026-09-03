defmodule Vutuv.Repo.Migrations.AvailabilityDefaultsOpenUp do
  use Ecto.Migration

  # What a member gets before they touch the availability block, once they have
  # said they are open to offers: seen by everyone rather than by signed-in
  # members alone, and matched against every shape of work rather than none.
  #
  # Both columns only mean anything once `employment_status` is set — it is nil
  # until the member says otherwise, and a nil status shows no badge to anybody
  # — so widening the defaults changes nothing for the members who never
  # answered, and for the ones who do it stops the answer from being narrowed
  # by a setting they were never asked about.
  #
  # **Defaults only, no backfill.** A stored value is a member's own decision,
  # including the ones that merely inherited the old default; overwriting a
  # visibility column would be changing a privacy setting on somebody's behalf.
  #
  # N-1 safe: the previous release writes both columns explicitly on every
  # save, so it neither reads nor depends on the default, and no column type
  # changes (no cached-plan blip).
  def up do
    execute("ALTER TABLE users ALTER COLUMN employment_status_visibility SET DEFAULT 'everyone'")

    execute(
      "ALTER TABLE users ALTER COLUMN desired_workplace_types SET DEFAULT ARRAY['onsite','hybrid','remote']::varchar[]"
    )
  end

  def down do
    execute("ALTER TABLE users ALTER COLUMN employment_status_visibility SET DEFAULT 'members'")

    execute(
      "ALTER TABLE users ALTER COLUMN desired_workplace_types SET DEFAULT ARRAY[]::varchar[]"
    )
  end
end
