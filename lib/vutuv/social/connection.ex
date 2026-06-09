defmodule Vutuv.Social.Connection do
  @moduledoc """
  A mutual, consented connection between two users — the LinkedIn-style
  relationship, distinct from the one-directional `Vutuv.Social.Follow`.

  Stored once per unordered pair, sorted (`user_a_id < user_b_id`, enforced by
  a check constraint) so the unique index allows exactly one connection per
  pair. `requested_by_id` is the party who sent the request (always one of the
  pair). `status` is pending → accepted | declined; accepting auto-creates a
  follow in both directions (see `Vutuv.Social.accept_connection/2`).
  `status_changed_at` anchors the re-request cooldown after a decline. All user
  fields are set programmatically, never cast.
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
