defmodule Vutuv.Chat.Conversation do
  @moduledoc false

  use VutuvWeb, :model

  @statuses ~w(pending accepted declined)

  schema "conversations" do
    # The unordered pair stored sorted (user_a_id < user_b_id, enforced by a
    # check constraint) so the unique index allows exactly one conversation
    # per pair. All four user fields are set programmatically, never cast.
    belongs_to(:user_a, Vutuv.Accounts.User)
    belongs_to(:user_b, Vutuv.Accounts.User)
    belongs_to(:initiator, Vutuv.Accounts.User)

    field(:status, :string, default: "pending")
    field(:last_message_at, :naive_datetime)

    has_many(:participants, Vutuv.Chat.Participant)
    has_many(:messages, Vutuv.Chat.Message)

    timestamps()
  end

  def statuses, do: @statuses

  def changeset(conversation, params \\ %{}) do
    conversation
    |> cast(params, [:status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:user_a_id, :user_b_id])
    |> check_constraint(:user_a_id, name: :sorted_pair, message: "pair must be sorted")
  end
end
