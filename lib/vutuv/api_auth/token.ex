defmodule Vutuv.ApiAuth.Token do
  @moduledoc """
  A bearer credential for the `/api/2.0` JSON API.

  One table holds every kind: personal access tokens (`kind: "pat"`, no
  app) and the OAuth access/refresh pairs (`kind: "access"/"refresh"`,
  tied to an app + grant). The plaintext token exists only in the moment of
  minting; `token_hash` is its SHA-256 and the only thing stored — see
  `Vutuv.ApiAuth`. `kind`, `token_hash` and all ids are set
  programmatically, never cast.
  """

  use VutuvWeb, :model

  alias Vutuv.ApiAuth.Scopes

  schema "api_tokens" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:app, Vutuv.ApiAuth.App)
    belongs_to(:grant, Vutuv.ApiAuth.Grant)

    field(:kind, :string)
    field(:token_hash, :string)
    # The user's label for a PAT ("CLI on my laptop").
    field(:name, :string)
    field(:scopes, {:array, :string}, default: [])
    field(:expires_at, :utc_datetime)
    field(:last_used_at, :utc_datetime)
    field(:revoked_at, :utc_datetime)

    timestamps()
  end

  @default_expiry_days 90

  @doc """
  Changeset for a user-created personal access token. Every token expires:
  a missing `expires_at` gets the #{@default_expiry_days}-day default here
  in the minting chokepoint, so no caller can create an eternal token by
  omission.
  """
  def pat_changeset(token, params \\ %{}) do
    token
    |> cast(params, [:name, :scopes, :expires_at])
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    |> validate_scopes()
    |> put_default_expiry()
    |> unique_constraint(:token_hash)
  end

  defp put_default_expiry(changeset) do
    case get_field(changeset, :expires_at) do
      nil ->
        expires = DateTime.add(DateTime.utc_now(:second), @default_expiry_days * 86_400)
        put_change(changeset, :expires_at, expires)

      _explicit ->
        changeset
    end
  end

  # An empty list equals the schema default, so Ecto records no change and
  # change-based validators never run — check the resulting field instead.
  defp validate_scopes(changeset) do
    changeset = validate_subset(changeset, :scopes, Scopes.all())

    case get_field(changeset, :scopes) do
      [_at_least_one | _] -> changeset
      _empty -> add_error(changeset, :scopes, "select at least one permission")
    end
  end
end
