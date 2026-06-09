defmodule Vutuv.Repo.Migrations.CreateConnections do
  use Ecto.Migration

  @moduledoc """
  The mutual, consented relationship (LinkedIn-style "connection"). One row per
  unordered pair, stored sorted (user_a_id < user_b_id, enforced by a check
  constraint) so the unique index guarantees exactly one connection per pair.

  `requested_by_id` is whoever sent the request (always one of the pair).
  `status`: pending → accepted | declined. A decline is silent (the requester
  is not notified); `status_changed_at` anchors the re-request cooldown so a
  declined request can be re-sent after it elapses.
  """

  def change do
    create table(:connections) do
      add(:user_a_id, references(:users, on_delete: :delete_all), null: false)
      add(:user_b_id, references(:users, on_delete: :delete_all), null: false)
      add(:requested_by_id, references(:users, on_delete: :delete_all), null: false)
      add(:status, :string, null: false, default: "pending")
      # When status last transitioned; the decline cooldown is measured from it.
      add(:status_changed_at, :naive_datetime)

      timestamps()
    end

    create(unique_index(:connections, [:user_a_id, :user_b_id]))
    create(constraint(:connections, :sorted_pair, check: "user_a_id < user_b_id"))
    create(index(:connections, [:user_b_id]))
    create(index(:connections, [:requested_by_id]))
  end
end
