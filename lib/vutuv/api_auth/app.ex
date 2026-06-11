defmodule Vutuv.ApiAuth.App do
  @moduledoc """
  A registered third-party application (OAuth client).

  `client_id` is the public identifier; the client secret is stored only as
  a SHA-256 hash (`client_secret_hash`, null for PKCE-only public clients).
  Registration is self-service; `suspended_at` is the admin kill switch.
  The OAuth authorization flow itself ships in a later phase — the table
  and schema exist so tokens and grants reference stable ids from day one.
  """

  use VutuvWeb, :model

  schema "oauth_apps" do
    belongs_to(:user, Vutuv.Accounts.User)

    field(:name, :string)
    field(:description, :string)
    field(:homepage_url, :string)
    field(:redirect_uris, {:array, :string}, default: [])
    field(:client_id, :string)
    field(:client_secret_hash, :string)
    field(:suspended_at, :utc_datetime)

    timestamps()
  end
end
