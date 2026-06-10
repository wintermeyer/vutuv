defmodule Vutuv.Repo.Migrations.CreateModeration do
  use Ecto.Migration

  def change do
    # One case per reported piece of content (post, message or whole user);
    # individual reports merge into the open case. Lifecycle:
    # pending_owner | flagged | escalated  →  resolved_deleted | resolved_edited
    # | upheld | rejected.
    create table(:moderation_cases) do
      add(:content_type, :string, null: false)
      add(:content_id, :binary_id, null: false)
      add(:owner_id, references(:users, on_delete: :delete_all), null: false)
      add(:status, :string, null: false)
      # The 72h self-service clock (only set while status = pending_owner).
      add(:owner_deadline_at, :naive_datetime)
      add(:escalated_at, :naive_datetime)
      add(:resolved_at, :naive_datetime)
      add(:resolved_by_id, references(:users, on_delete: :nilify_all))
      # What the content said when it was reported, so admins can still rule
      # after the owner edits it.
      add(:content_snapshot, :text)

      timestamps()
    end

    create(index(:moderation_cases, [:status]))
    create(index(:moderation_cases, [:owner_id]))

    # At most one open case per content item; closed cases stay as history.
    create(
      unique_index(:moderation_cases, [:content_type, :content_id],
        where: "status IN ('pending_owner', 'flagged', 'escalated')",
        name: :moderation_cases_open_content_index
      )
    )

    create table(:moderation_reports) do
      add(:case_id, references(:moderation_cases, on_delete: :delete_all), null: false)
      add(:reporter_id, references(:users, on_delete: :delete_all), null: false)
      add(:category, :string, null: false)
      add(:note, :text)
      # Set by an admin when the report itself was a weapon; earns the
      # reporter a strike.
      add(:abusive?, :boolean, default: false, null: false)

      timestamps()
    end

    create(unique_index(:moderation_reports, [:case_id, :reporter_id]))
    create(index(:moderation_reports, [:reporter_id]))

    create table(:moderation_strikes) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:case_id, references(:moderation_cases, on_delete: :nilify_all))
      # "owner" (upheld violation) or "reporter" (abusive report).
      add(:role, :string, null: false)
      # The ladder level applied at issuance: 1 warn, 2 suspend, 3 deactivate.
      add(:level, :integer, null: false)
      add(:reason, :text)
      add(:issued_by_id, references(:users, on_delete: :nilify_all))
      add(:expires_at, :naive_datetime, null: false)

      timestamps()
    end

    create(index(:moderation_strikes, [:user_id]))

    alter table(:posts) do
      add(:frozen_at, :naive_datetime)
    end

    alter table(:messages) do
      add(:frozen_at, :naive_datetime)
    end

    alter table(:users) do
      # Profile frozen pending moderation (hidden from everyone but owner/admins).
      add(:frozen_at, :naive_datetime)
      # Strike 2: temporary suspension (login blocked, profile hidden).
      add(:suspended_until, :naive_datetime)
      # Strike 3: permanent deactivation.
      add(:deactivated_at, :naive_datetime)
    end
  end
end
