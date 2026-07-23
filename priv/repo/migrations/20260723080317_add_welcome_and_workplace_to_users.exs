defmodule Vutuv.Repo.Migrations.AddWelcomeAndWorkplaceToUsers do
  use Ecto.Migration

  # Two additive columns for the one-time welcome page (/system/welcome), the
  # screen a brand-new member meets right after their registration PIN:
  #
  #   * welcome_completed_at — when they finished (or skipped) that page. NULL
  #     means "not seen yet", the single gate both the post-PIN redirect and the
  #     page itself read. Every account that exists today is long past sign-up,
  #     so the backfill stamps them all: without it every legacy account would
  #     meet a welcome page it never asked for on its next login.
  #   * desired_workplace_type — the member's preferred workplace form, in the
  #     same vocabulary a job posting uses (onsite | hybrid | remote); NULL = no
  #     preference. It belongs to the availability signal (issue #870) and is
  #     shown under that status's visibility.
  #
  # Both are plain nullable additions, so the currently deployed release keeps
  # working unchanged (N-1).
  def up do
    alter table(:users) do
      add(:welcome_completed_at, :naive_datetime)
      add(:desired_workplace_type, :string)
    end

    # Existing members have no welcome page to see; mark them done.
    execute("UPDATE users SET welcome_completed_at = NOW() AT TIME ZONE 'utc'")
  end

  def down do
    alter table(:users) do
      remove(:welcome_completed_at)
      remove(:desired_workplace_type)
    end
  end
end
