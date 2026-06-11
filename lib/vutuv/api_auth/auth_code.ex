defmodule Vutuv.ApiAuth.AuthCode do
  @moduledoc """
  A one-time OAuth authorization code (10-minute lifetime) with its PKCE
  challenge. `used_at` marks consumption; a second redemption is the RFC
  6749/9700 token-theft signal and revokes the grant's tokens. Populated by
  the OAuth flow (a later phase).
  """

  use VutuvWeb, :model

  schema "oauth_auth_codes" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:app, Vutuv.ApiAuth.App)
    belongs_to(:grant, Vutuv.ApiAuth.Grant)

    field(:code_hash, :string)
    field(:redirect_uri, :string)
    field(:scopes, {:array, :string}, default: [])
    field(:code_challenge, :string)
    field(:code_challenge_method, :string, default: "S256")
    field(:expires_at, :utc_datetime)
    field(:used_at, :utc_datetime)

    timestamps(updated_at: false)
  end
end
