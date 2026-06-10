defmodule Vutuv.Chat.Message do
  @moduledoc false

  use VutuvWeb, :model

  @max_body_length 10_000

  schema "messages" do
    field(:body, :string)
    # Set while the message is in the moderation freezer: hidden from the
    # other participant. Managed by Vutuv.Moderation, never cast.
    field(:frozen_at, :naive_datetime)

    belongs_to(:conversation, Vutuv.Chat.Conversation)
    # Nullable: a deleted sender's messages survive for the other participant.
    belongs_to(:sender, Vutuv.Accounts.User)

    timestamps()
  end

  def max_body_length, do: @max_body_length

  def changeset(message, params \\ %{}) do
    message
    |> cast(params, [:body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body])
    |> validate_length(:body, max: @max_body_length)
  end
end
