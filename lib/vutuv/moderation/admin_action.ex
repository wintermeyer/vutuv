defmodule Vutuv.Moderation.AdminAction do
  @moduledoc """
  One admin-initiated moderation action on an account (issue #812): the account
  was frozen or unfrozen directly from the admin account tool, without a report
  or a `Vutuv.Moderation.Case`. The audit trail behind the caseless admin
  freeze, mirroring `Vutuv.Deliverability.Event` and `Vutuv.Moderation.Event`.

  `actor_id` is the admin who acted. `user_id` / `actor_id` are plain values,
  not associations: like the deliverability ledger this is an immutable record
  that must stay readable after the rows it references are gone. Rows are
  inserted by `Vutuv.Moderation` only, never built from user params.
  """

  use VutuvWeb, :model

  @actions ~w(account_frozen account_unfrozen)

  schema "moderation_admin_actions" do
    field(:user_id, :binary_id)
    field(:actor_id, :binary_id)
    field(:action, :string)
    field(:reason, :string)
    field(:detail, :map, default: %{})

    timestamps(updated_at: false)
  end

  @doc "The closed set of `action` values this ledger records."
  def actions, do: @actions
end
