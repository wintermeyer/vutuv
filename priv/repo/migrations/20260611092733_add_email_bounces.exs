defmodule Vutuv.Repo.Migrations.AddEmailBounces do
  use Ecto.Migration

  def change do
    # The bounce ledger: one row per failure DSN that came back to the bounce
    # mailbox (POST /webhooks/bounces). email_value is a plain string, not an
    # FK - bounces may name addresses whose owner has since left.
    create table(:email_bounces) do
      add(:email_value, :string, null: false)
      add(:action, :string, null: false)
      add(:status, :string)
      add(:raw, :text, null: false)

      timestamps(updated_at: false)
    end

    create(index(:email_bounces, [:email_value]))

    alter table(:emails) do
      # Set by a failure DSN, cleared by a successful login PIN through the
      # address. While set, Emailer.deliver/1 drops automatic mail to it.
      add(:undeliverable_at, :naive_datetime)
    end

    # Both changes are additive and N-1 safe: the currently deployed release
    # never touches the new table or column.
  end
end
