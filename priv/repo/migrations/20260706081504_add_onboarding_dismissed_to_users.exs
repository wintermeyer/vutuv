defmodule Vutuv.Repo.Migrations.AddOnboardingDismissedToUsers do
  use Ecto.Migration

  def change do
    # The owner's profile-completion checklist auto-hides an hour after sign-up;
    # this flag lets a member close it "for good" with the × before then. A plain
    # nullable-with-default addition, so the currently deployed release keeps
    # working through the blue/green switch.
    alter table(:users) do
      add(:onboarding_dismissed?, :boolean, default: false, null: false)
    end
  end
end
