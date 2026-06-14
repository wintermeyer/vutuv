defmodule Vutuv.Repo.Migrations.AddEmailTypeToEmails do
  use Ecto.Migration

  # Mirrors phone_numbers.number_type: a Work/Personal/Other label on each
  # address. Adding the column with a DB default backfills every existing row
  # to "Other" in one statement, and keeps the change N-1 compatible: the
  # currently deployed release knows nothing of email_type, so its inserts
  # rely on this default to satisfy the NOT NULL.
  def change do
    alter table(:emails) do
      add(:email_type, :string, default: "Other", null: false)
    end
  end
end
