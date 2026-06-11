defmodule Vutuv.Repo.Migrations.CreateAds do
  use Ecto.Migration

  # Plain addition (new table only), so this is N-1 compatible in one deploy.
  def change do
    create table(:ads) do
      # The calendar day (Europe/Berlin) the ad runs on - one ad per day.
      add(:day, :date, null: false)
      # The ad text: Markdown, at most 2048 characters (enforced in the
      # changeset; the column is text so multi-byte content always fits).
      add(:content, :text, null: false)

      # The price agreed at booking time, in cents (1250 EUR net today).
      add(:price_cents, :integer, null: false)

      # The invoice address as entered by the booker. Kept on the booking
      # record even though it is also mailed out - the row is the receipt.
      add(:billing_name, :string, null: false)
      add(:billing_company, :string)
      add(:billing_street, :string, null: false)
      add(:billing_zip_code, :string, null: false)
      add(:billing_city, :string, null: false)
      add(:billing_country, :string, null: false)
      add(:vat_id, :string)

      # Nullable + nilify: a booked ad keeps running (and the booking record
      # survives for the books) even if the booker deletes their account, so
      # Accounts.delete_user/1 needs no extra step for ads.
      add(:user_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      timestamps()
    end

    # One ad per calendar day - the booking invariant.
    create(unique_index(:ads, [:day]))
    create(index(:ads, [:user_id]))
  end
end
