defmodule Vutuv.Repo.Migrations.CreateFediversePrivateMessages do
  use Ecto.Migration

  def change do
    create table(:fediverse_private_messages, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:post_id, references(:posts, type: :binary_id, on_delete: :delete_all))
      add(:body, :text, null: false)
      add(:object_uri, :text, null: false)
      add(:in_reply_to_uri, :text)
      add(:recipient_actor_uri, :text, null: false)
      timestamps()
    end

    create(unique_index(:fediverse_private_messages, [:object_uri]))
    create(index(:fediverse_private_messages, [:user_id, :in_reply_to_uri, :id]))
    create(index(:fediverse_private_messages, [:post_id]))
  end
end
