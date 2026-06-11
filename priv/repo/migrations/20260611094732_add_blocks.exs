defmodule Vutuv.Repo.Migrations.AddBlocks do
  use Ecto.Migration

  def change do
    # One row per active block (Vutuv.Social.Block). conversation_id remembers
    # which conversation THIS block froze, so unblocking only thaws its own
    # freeze (a moderation severance's freeze stays). Additive, N-1 safe.
    create table(:blocks) do
      add(:blocker_id, references(:users, on_delete: :delete_all), null: false)
      add(:blocked_id, references(:users, on_delete: :delete_all), null: false)
      add(:conversation_id, references(:conversations, on_delete: :nilify_all))

      timestamps(updated_at: false)
    end

    create(unique_index(:blocks, [:blocker_id, :blocked_id]))
    create(index(:blocks, [:blocked_id]))
  end
end
