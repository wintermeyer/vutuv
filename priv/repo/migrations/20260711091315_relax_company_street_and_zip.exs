defmodule Vutuv.Repo.Migrations.RelaxCompanyStreetAndZip do
  use Ecto.Migration

  # Street address and postal code become optional on company pages: some
  # countries have no postal-code system at all (Ireland pre-Eircode, the UAE,
  # Hong Kong, …) and not every operator wants to publish a street. City and
  # country stay NOT NULL (they are the location filter keys + the JSON-LD
  # addressLocality/addressCountry). Dropping NOT NULL is N-1 safe: the previous
  # release still validates both present, so it keeps writing non-null values
  # into the now-nullable columns.
  def up do
    alter table(:companies) do
      modify(:street_address, :string, null: true)
      modify(:zip_code, :string, null: true)
    end
  end

  def down do
    alter table(:companies) do
      modify(:street_address, :string, null: false)
      modify(:zip_code, :string, null: false)
    end
  end
end
