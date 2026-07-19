defmodule Vutuv.Repo.Migrations.CreateHandleChangeNotifications do
  use Ecto.Migration

  # One durable notification per affected post author when a member renames: it
  # carries the point-in-time old + new handle (the derived notification feed
  # only ever reflects *current* state, so this fact has nowhere else to live)
  # and the ids of that author's posts whose @old mentions were rewritten to
  # @new. A plain addition — safe in one blue/green deploy.
  def change do
    create table(:handle_change_notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :recipient_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :actor_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :old_handle, :string, null: false
      add :new_handle, :string, null: false
      add :post_ids, {:array, :binary_id}, null: false, default: []

      # Never updated after insert; the feed orders and unread-counts by this.
      timestamps(updated_at: false)
    end

    # The notification feed reads a recipient's rows newest-first.
    create index(:handle_change_notifications, [:recipient_id, :inserted_at])
    create index(:handle_change_notifications, [:actor_id])
  end
end
