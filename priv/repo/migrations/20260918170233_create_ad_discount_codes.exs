defmodule Vutuv.Repo.Migrations.CreateAdDiscountCodes do
  use Ecto.Migration

  # Discount codes an admin hands out for ad bookings.
  #
  # **The code IS the row's id.** A UUID v7 is unguessable, so there is no
  # second column to keep unique and no way to mint a code that collides with
  # one already out there.
  #
  # **Percent or euro, never both**, enforced in the database as well as the
  # changeset: a row carrying both would be a price nobody can compute, and the
  # one place that must not be left to a validation somebody forgets to run is
  # the money.
  #
  # `user_id` set means the code belongs to that member alone. Redemptions are
  # their own rows rather than a counter, because "once per member" is a fact
  # about a pair, and because an admin who hands out a code wants to see who
  # used it.
  def change do
    create table(:ad_discount_codes) do
      add(:percent_off, :integer)
      add(:cents_off, :integer)
      add(:expires_on, :date, null: false)
      add(:note, :string)
      add(:user_id, references(:users, on_delete: :delete_all))
      add(:created_by_id, references(:users, on_delete: :nilify_all))
      timestamps()
    end

    create(index(:ad_discount_codes, [:user_id]))
    create(index(:ad_discount_codes, [:expires_on]))

    create(
      constraint(:ad_discount_codes, :percent_or_cents,
        check: """
        (percent_off IS NOT NULL AND cents_off IS NULL
         AND percent_off BETWEEN 1 AND 100)
        OR
        (cents_off IS NOT NULL AND percent_off IS NULL
         AND cents_off BETWEEN 100 AND 300000)
        """
      )
    )

    create table(:ad_discount_redemptions) do
      add(:code_id, references(:ad_discount_codes, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      # The first day of the purchase it paid for, so an admin can follow it.
      add(:ad_id, references(:ads, on_delete: :nilify_all))
      add(:cents_off, :integer, null: false)
      # A booking we turned down, or one withdrawn before it was approved, gives
      # the code back: nothing ran, so nothing was used. Stamped rather than
      # deleted, so the history of who tried what survives.
      add(:released_at, :utc_datetime)
      timestamps()
    end

    create(index(:ad_discount_redemptions, [:code_id]))

    # "Once per member", and for a personalised code that is "once" outright.
    # Partial, so a released redemption lets the member use the code again.
    create(
      unique_index(:ad_discount_redemptions, [:code_id, :user_id],
        where: "released_at IS NULL",
        name: :ad_discount_redemptions_live_index
      )
    )

    # What a booking was given, stamped on the row beside the price it was
    # booked at - the invoice is written from these two, so neither may be
    # recomputed later from a code that has since changed or expired.
    alter table(:ads) do
      add(:discount_code_id, references(:ad_discount_codes, on_delete: :nilify_all))
      add(:discount_cents, :integer, null: false, default: 0)
    end

    create(index(:ads, [:discount_code_id]))
  end
end
