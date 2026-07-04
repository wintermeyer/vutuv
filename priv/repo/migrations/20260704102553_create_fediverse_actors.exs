defmodule Vutuv.Repo.Migrations.CreateFediverseActors do
  use Ecto.Migration

  @moduledoc """
  One row per member who takes part in the Fediverse (follow-only ActivityPub
  federation): the actor's RSA keypair, created lazily when the member opts in.
  The keys sign outbound deliveries (HTTP Signatures) and are published in the
  actor document. Plain addition, N-1 safe.
  """

  def change do
    create table(:fediverse_actors) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:private_key_pem, :text, null: false)
      add(:public_key_pem, :text, null: false)

      timestamps()
    end

    create(unique_index(:fediverse_actors, [:user_id]))
  end
end
