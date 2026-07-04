defmodule Vutuv.Repo.Migrations.CreateFediverseFollowers do
  use Ecto.Migration

  @moduledoc """
  Remote (Fediverse) followers of a member: the remote actor's id URI plus the
  inbox to deliver to (and its sharedInbox, so one server with many followers
  gets each post once). Written by the inbox on Follow/Undo. Plain addition,
  N-1 safe.
  """

  def change do
    create table(:fediverse_followers) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:actor_uri, :text, null: false)
      add(:inbox_uri, :text, null: false)
      add(:shared_inbox_uri, :text)

      timestamps()
    end

    create(unique_index(:fediverse_followers, [:user_id, :actor_uri]))
  end
end
