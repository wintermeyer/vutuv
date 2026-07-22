defmodule Vutuv.Repo.Migrations.AddCvUpdateAnnouncements do
  use Ecto.Migration

  # CV update notifications (issue #980): when a member adds a new CV entry —
  # a work experience, an education entry, a certificate or license — they may
  # tell the people who follow them about it.
  #
  # Two flags, one per side:
  #   * `announce_to_followers?` on each CV table is the AUTHOR's choice, made
  #     once when the entry is created (the edit form never offers it, and the
  #     changeset only casts it on insert). Default false, so neither the
  #     existing rows nor the LinkedIn import ever announce anything.
  #   * `cv_update_notifications?` on users is the READER's opt-out. Default
  #     true: the notification is the point of the feature and it only fires
  #     for people the reader deliberately follows, but it can be noisy, so one
  #     switch on the notification settings page turns it off for good.
  #
  # Plain additive columns with defaults, so the previous release keeps working
  # untouched during the blue/green window (N-1 safe).
  def change do
    alter table(:work_experiences) do
      add(:announce_to_followers?, :boolean, null: false, default: false)
    end

    alter table(:educations) do
      add(:announce_to_followers?, :boolean, null: false, default: false)
    end

    alter table(:qualifications) do
      add(:announce_to_followers?, :boolean, null: false, default: false)
    end

    alter table(:users) do
      add(:cv_update_notifications?, :boolean, null: false, default: true)
    end

    # The notification feed reads "announced entries of the people I follow,
    # newest first". Partial indexes over the announced rows only: the flag is
    # false for everything that exists today, so these stay tiny.
    create(
      index(:work_experiences, [:user_id, :inserted_at],
        where: ~s|"announce_to_followers?"|,
        name: :work_experiences_announced_index
      )
    )

    create(
      index(:educations, [:user_id, :inserted_at],
        where: ~s|"announce_to_followers?"|,
        name: :educations_announced_index
      )
    )

    create(
      index(:qualifications, [:user_id, :inserted_at],
        where: ~s|"announce_to_followers?"|,
        name: :qualifications_announced_index
      )
    )
  end
end
