defmodule Vutuv.Fediverse.Delivery do
  @moduledoc """
  One queued outbound ActivityPub delivery: an activity (JSON, built at
  enqueue time) headed for one remote inbox, signed with the member's actor
  key when `Vutuv.Fediverse.Deliverer` sends it. Mirrors the webhook queue:
  exponential backoff on failure, dropped after repeated failure, row deleted
  on success.
  """

  use VutuvWeb, :model

  schema "fediverse_deliveries" do
    field(:inbox_uri, :string)
    field(:activity_json, :string)
    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime)
    field(:last_error, :string)

    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end
end
