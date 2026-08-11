defmodule Vutuv.Repo.Migrations.AddOrganizationToFediversePostDeliveries do
  @moduledoc """
  Issue #1334: the ledger of where a post's copies went can name a **page** as
  the sender.

  `fediverse_post_deliveries` is the takedown ledger (issue #1102): it remembers
  which inbox got which object URI, so a revocation is addressed to the servers
  that actually received a copy rather than broadcast at whoever follows today.
  A page's post needs the same, or taking one down would reach nobody.

  Like `user_id` beside it, this is a **plain column, not a reference**, and
  carries no CHECK. That is the existing shape of this table and it is
  deliberate: a revocation has to outlive the post *and* its author, so a
  foreign key would delete the very rows the takedown still needs. The pair is
  therefore an invariant of the writer (`record_post_deliveries/3` sets exactly
  one), not of the schema — which is why `drop_post_deliveries/1` has to be
  explicit for both kinds instead of relying on a cascade.

  N-1 safe: a plain nullable column the previous release never reads.
  """
  use Ecto.Migration

  def up do
    alter table(:fediverse_post_deliveries) do
      add(:organization_id, :binary_id)
    end

    # `user_id` has to give up NOT NULL, or a page's row cannot be written at
    # all — which is how the first attempt failed, loudly and immediately.
    execute("ALTER TABLE fediverse_post_deliveries ALTER COLUMN user_id DROP NOT NULL")

    create(index(:fediverse_post_deliveries, [:organization_id]))
  end

  def down do
    drop(index(:fediverse_post_deliveries, [:organization_id]))

    execute("DELETE FROM fediverse_post_deliveries WHERE user_id IS NULL")
    execute("ALTER TABLE fediverse_post_deliveries ALTER COLUMN user_id SET NOT NULL")

    alter table(:fediverse_post_deliveries) do
      remove(:organization_id)
    end
  end
end
