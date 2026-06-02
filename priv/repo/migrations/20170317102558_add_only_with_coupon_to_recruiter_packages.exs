defmodule Vutuv.Repo.Migrations.AddOnlyWithVoucherToRecruiterPackages do
  use Ecto.Migration

  def change do
    alter table (:recruiter_packages) do
      add :only_with_coupon, :boolean, default: false
    end
  end
end
