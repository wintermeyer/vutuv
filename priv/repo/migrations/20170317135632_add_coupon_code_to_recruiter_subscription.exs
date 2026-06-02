defmodule Vutuv.Repo.Migrations.AddCouponCodeToRecruiterSubscription do
  use Ecto.Migration

  def change do
    alter table :recruiter_subscriptions do
      add :coupon_code, :string
    end
  end
end
