defmodule Vutuv.Deliverability.Event do
  @moduledoc """
  One recorded deliverability state transition: an address was deactivated or
  recovered, or an account was frozen-for-unreachability or thawed. The audit
  trail behind the admin deliverability dashboard, mirroring
  `Vutuv.Moderation.Event`.

  `actor_id` is the admin who acted, or `nil` for an automatic (system)
  transition. `user_id` / `email_value` are plain values, not associations:
  like `EmailBounce`, this is an immutable ledger that must stay readable after
  the rows it references are gone. Rows are inserted by `Vutuv.Deliverability`
  only, never built from user params.
  """

  use VutuvWeb, :model

  @actions ~w(address_deactivated address_recovered account_frozen account_thawed)

  schema "deliverability_events" do
    field(:user_id, :binary_id)
    field(:email_value, :string)
    field(:actor_id, :binary_id)
    field(:action, :string)
    field(:detail, :map, default: %{})

    timestamps(updated_at: false)
  end

  @doc "The closed set of `action` values this ledger records."
  def actions, do: @actions
end
