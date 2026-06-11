defmodule Vutuv.Webhooks.Delivery do
  @moduledoc """
  One queued webhook delivery: the thin event envelope (`payload`) for one
  subscription. `next_attempt_at` drives the poller, exponential backoff
  bumps it on failure, `delivered_at` closes the row. All fields are set
  programmatically by `Vutuv.Webhooks`.
  """

  use VutuvWeb, :model

  schema "webhook_deliveries" do
    belongs_to(:subscription, Vutuv.Webhooks.Subscription)

    field(:event, :string)
    field(:payload, :map, default: %{})
    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime)
    field(:delivered_at, :utc_datetime)
    field(:last_status, :integer)
    field(:last_error, :string)

    timestamps()
  end
end
