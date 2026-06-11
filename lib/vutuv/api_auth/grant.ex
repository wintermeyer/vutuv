defmodule Vutuv.ApiAuth.Grant do
  @moduledoc """
  A user's authorization of an app: which scopes they granted, once per
  user × app. Revoking sets `revoked_at` and kills the grant's tokens;
  re-authorizing reuses the row. The "Connected apps" settings page lists
  these. Populated by the OAuth flow (a later phase).
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
