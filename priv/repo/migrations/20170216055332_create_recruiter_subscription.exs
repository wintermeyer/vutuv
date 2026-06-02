defmodule Vutuv.Repo.Migrations.CreateRecruiterSubscription do
  use Ecto.Migration

  def change do
    create table(:recruiter_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all)
      add :recruiter_package_id, references(:recruiter_packages, on_delete: :delete_all)
      add :subscription_begins, :date
      add :subscription_ends, :date
      add :line1, :string
      add :line2, :string
      add :street, :string
      add :zip_code, :string
      add :city, :string
      add :country, :string
      add :invoice_number, :string
      add :invoiced_on, :date
      add :paid, :boolean
      add :paid_on, :date

      timestamps()
    end
    create unique_index(:recruiter_subscriptions, [:invoice_number], unique: true)
  end
end
