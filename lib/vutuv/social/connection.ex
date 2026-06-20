defmodule Vutuv.Social.Connection do
  @moduledoc """
  **Legacy schema, kept only so historical migrations compile.** The live model
  no longer has a separate connection record: two people are "vernetzt"
  (connected) exactly when they follow each other (`Vutuv.Social.connected?/2`),
  derived from `Vutuv.Social.Follow`. The request / accept / decline flow this
  schema backed is gone.

  The `connections` table still exists (it is dropped in a later expand/contract
  deploy), and `Vutuv.Social.backfill_connections_from_mutual_follows/0` — called
  by a historical migration — still references this schema. Nothing else does.

  Stored once per unordered pair, sorted (`user_a_id < user_b_id`, enforced by a
  check constraint). `requested_by_id` is the party who sent the request;
  `status` is pending → accepted | declined.
  """

  use VutuvWeb, :model

  @statuses ~w(pending accepted declined)

  schema "connections" do
    belongs_to(:user_a, Vutuv.Accounts.User)
    belongs_to(:user_b, Vutuv.Accounts.User)
    # Whoever opened the request — the pending "connection request" sender.
    belongs_to(:requested_by, Vutuv.Accounts.User)

    field(:status, :string, default: "pending")
    field(:status_changed_at, :naive_datetime)

    timestamps()
  end

  def statuses, do: @statuses

  def changeset(connection, params \\ %{}) do
    connection
    |> cast(params, [:status, :status_changed_at])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:user_a_id, :user_b_id])
    |> check_constraint(:user_a_id, name: :sorted_pair, message: "pair must be sorted")
  end
end
