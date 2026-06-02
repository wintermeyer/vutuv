defmodule Vutuv.Repo.Migrations.AddValidToCoupon do
  use Ecto.Migration

  def change do
    alter table (:coupons) do
      add :valid, :boolean, default: true
    end
  end
end
