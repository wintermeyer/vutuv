defmodule Vutuv.Repo.Migrations.AllowAdsWithoutBillingCountry do
  use Ecto.Migration

  # Most invoices stay in the country the installation bills from, where
  # writing it out says nothing, so the field is optional now.
  #
  # Widening a NOT NULL column is the change that usually needs every `IN` /
  # `NOT IN`, join and `Repo.get` on it walked first. This one is display-only:
  # nothing queries or joins on `billing_country`, and all four places that
  # render it already drop a blank line (`Enum.reject(&(&1 in [nil, ""]))` on
  # the admin page, `join_present/2` in the operator mail, `|| ""` in the
  # booking wizard, a plain field list in the data export).
  #
  # N-1 safe: the release still serving traffic during the blue/green switch
  # always writes a value, so a column that merely permits NULL cannot break it.
  def up do
    alter table(:ads) do
      modify(:billing_country, :string, null: true)
    end
  end

  def down do
    execute("UPDATE ads SET billing_country = '' WHERE billing_country IS NULL")

    alter table(:ads) do
      modify(:billing_country, :string, null: false)
    end
  end
end
