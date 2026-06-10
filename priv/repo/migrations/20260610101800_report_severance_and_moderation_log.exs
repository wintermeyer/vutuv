defmodule Vutuv.Repo.Migrations.ReportSeveranceAndModerationLog do
  use Ecto.Migration

  @moduledoc """
  Reporting someone now separates the two accounts on the spot: connection
  and follows are removed, the 1:1 conversation is frozen for both sides
  (`conversations.frozen_at`). `moderation_severances` records what existed
  so a rejected report can restore it; `moderation_events` is the per-case
  audit log the admins read.
  """

  def change do
    alter table(:conversations) do
      add(:frozen_at, :naive_datetime)
    end

    create table(:moderation_severances) do
      add(:case_id, references(:moderation_cases, on_delete: :delete_all), null: false)
      add(:reporter_id, references(:users, on_delete: :delete_all), null: false)
      add(:owner_id, references(:users, on_delete: :delete_all), null: false)
      add(:had_connection, :boolean, null: false, default: false)
      add(:connection_status, :string)
      add(:connection_requested_by_id, references(:users, on_delete: :nilify_all))
      add(:had_follow_reporter_to_owner, :boolean, null: false, default: false)
      add(:had_follow_owner_to_reporter, :boolean, null: false, default: false)
      add(:conversation_id, references(:conversations, on_delete: :nilify_all))
      add(:restored_at, :naive_datetime)
      timestamps()
    end

    create(index(:moderation_severances, [:case_id]))
    create(index(:moderation_severances, [:reporter_id]))
    create(index(:moderation_severances, [:owner_id]))

    create table(:moderation_events) do
      add(:case_id, references(:moderation_cases, on_delete: :delete_all), null: false)
      add(:actor_id, references(:users, on_delete: :nilify_all))
      add(:action, :string, null: false)
      add(:detail, :map, null: false, default: %{})
      timestamps(updated_at: false)
    end

    create(index(:moderation_events, [:case_id, :inserted_at]))
  end
end
