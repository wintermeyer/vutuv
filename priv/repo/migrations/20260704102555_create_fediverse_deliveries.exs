defmodule Vutuv.Repo.Migrations.CreateFediverseDeliveries do
  use Ecto.Migration

  @moduledoc """
  The outbound ActivityPub delivery queue (mirrors the webhooks queue): one row
  per activity per remote inbox, signed and POSTed by Vutuv.Fediverse.Deliverer
  with exponential backoff; dropped after repeated failure. The signing member
  is referenced so the row dies with the account. Plain addition, N-1 safe.
  """

  def change do
    create table(:fediverse_deliveries) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:inbox_uri, :text, null: false)
      add(:activity_json, :text, null: false)
      add(:attempts, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime, null: false)
      add(:last_error, :string)

      timestamps()
    end

    create(index(:fediverse_deliveries, [:next_attempt_at]))
  end
end
