defmodule Vutuv.Repo.Migrations.CreateCoupon do
  use Ecto.Migration

  def change do
    create table(:coupons) do
      add :code, :string
      add :user_id, :integer
      add :recruiter_package_id, :integer
      add :amount, :decimal
      add :percentage, :integer
      add :ends_on, :date

      timestamps()
    end

    create unique_index(:coupons, [:code])
  end
end
