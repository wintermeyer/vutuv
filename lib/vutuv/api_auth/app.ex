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

  @doc """
  The developer-facing fields. `client_id`/`client_secret_hash`/owner are
  set programmatically. Redirect URIs must be exact `https://` URLs
  (`http://localhost` allowed for development) — the authorize endpoint
  only ever redirects to an exact match.
  """
  def changeset(app, params \\ %{}) do
    app
    |> cast(params, [:name, :description, :homepage_url, :redirect_uris])
    |> validate_required([:name])
    |> validate_length(:name, max: 60)
    |> validate_length(:description, max: 500)
    |> validate_length(:homepage_url, max: 255)
    |> update_change(:redirect_uris, &clean_uris/1)
    |> validate_redirect_uris()
    |> unique_constraint(:client_id)
  end

  defp clean_uris(uris) when is_list(uris) do
    uris |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp clean_uris(other), do: other

  # An empty list equals the schema default (no change recorded), so check
  # the resulting field — same pitfall as the token scopes.
  defp validate_redirect_uris(changeset) do
    case get_field(changeset, :redirect_uris) do
      [_at_least_one | _] = uris ->
        if Enum.all?(uris, &valid_redirect_uri?/1) do
          changeset
        else
          add_error(
            changeset,
            :redirect_uris,
            "must be exact https:// URLs (http://localhost is allowed for development)"
          )
        end

      _empty ->
        add_error(changeset, :redirect_uris, "needs at least one redirect URL")
    end
  end

  @doc false
  def valid_redirect_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1"] -> true
      _other -> false
    end
  end
end
