defmodule Vutuv.Repo.Migrations.CreateAdCreatives do
  use Ecto.Migration

  # A member's saved ad texts, so booking a second week does not mean typing
  # the same three lines again. Deliberately its own table rather than a flag
  # on `ads`: a booking COPIES the text onto its rows, so editing a saved ad
  # can never rewrite an ad that is already running or already approved.
  #
  # A plain new table, so the release still serving traffic during the
  # blue/green switch is untouched by it.
  def change do
    create table(:ad_creatives) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:title, :string, null: false)
      add(:body, :string, null: false)
      add(:url, :string, null: false)
      timestamps()
    end

    create(index(:ad_creatives, [:user_id, :updated_at]))
  end
end
