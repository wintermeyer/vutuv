defmodule Vutuv.Accounts.SlugChange do
  @moduledoc """
  One row per username change: the ledger behind the change rate limit
  (4 changes per rolling 90 days, see `Vutuv.Accounts.slug_change_quota/1`).
  `value` records the handle the member changed *to*, purely as an audit
  trail - old handles are neither reserved nor redirected.
  """

  use VutuvWeb, :model

  schema "slug_changes" do
    field(:value, :string)
    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end
end
