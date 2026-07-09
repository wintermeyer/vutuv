defmodule Vutuv.Repo.Migrations.AddModerationReasonToUsers do
  use Ecto.Migration

  # Internal, reversible moderation mark. Set alongside deactivated_at when an
  # admin removes an account from a moderation case (e.g. "spam"); cleared on
  # restore. Never user-cast (set only by Vutuv.Moderation / Vutuv.Accounts via
  # update_all), so no changeset validate_length is needed. Plain nullable
  # column add: backward-compatible for the previous release (N-1).
  def change do
    alter table(:users) do
      add(:moderation_reason, :string)
    end
  end
end
