defmodule Vutuv.ApiAuth.Grant do
  @moduledoc """
  A user's authorization of an app: which scopes they granted, once per
  user × app (written by the consent flow, `Vutuv.ApiAuth.OAuth`).
  Revoking sets `revoked_at` and kills the grant's tokens; re-consent
  reuses the row. The "Connected apps" page lists these.
  """

  use VutuvWeb, :model

  schema "oauth_grants" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:app, Vutuv.ApiAuth.App)

    field(:scopes, {:array, :string}, default: [])
    field(:revoked_at, :utc_datetime)

    timestamps()
  end
end
