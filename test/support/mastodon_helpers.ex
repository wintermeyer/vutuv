defmodule Vutuv.MastodonHelpers do
  @moduledoc """
  What every Mastodon-adapter test needs before it can make a request: an
  identity that allows client apps at all, an access token for it, and a conn
  pointed at a host that serves the adapter.

  The switch matters. `mastodon_clients?` ships **off** for members and for
  pages — signing in from a phone app is opted into, not out of — so a test
  that mints a token for a plain `insert(:activated_user)` gets a valid token
  that every endpoint then refuses. `mastodon_token/3` turns the switch on the
  way a member does, which is also what keeps the tests honest about the
  default: flip it back to on and nothing here starts passing that was failing,
  but `test/vutuv_web/controllers/settings_controller_test.exs` will say so.
  """

  import Vutuv.Factory

  alias Ecto.Changeset
  alias Vutuv.Accounts.User
  alias Vutuv.ApiAuth
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Repo

  @doc "Turns an identity's Mastodon-app switch on, as its owner would."
  def allow_mastodon_clients(%User{} = user),
    do: user |> Changeset.change(mastodon_clients?: true) |> Repo.update!()

  def allow_mastodon_clients(%Organization{} = organization) do
    {:ok, organization} = Organizations.set_mastodon_clients(organization, true)
    organization
  end

  @doc """
  Turns the switch back off, reading the row rather than trusting the struct
  the caller is holding.

  `Changeset.change/2` compares against the struct it is given, so switching a
  stale copy back to `false` is **no change at all** and writes nothing — the
  row stays on and the opt-out test passes for the wrong reason. Reload first.
  """
  def deny_mastodon_clients(%User{} = user),
    do: user |> Repo.reload!() |> Changeset.change(mastodon_clients?: false) |> Repo.update!()

  def deny_mastodon_clients(%Organization{} = organization) do
    {:ok, organization} =
      organization |> Repo.reload!() |> Organizations.set_mastodon_clients(false)

    organization
  end

  @doc """
  An unattended client registration, the row `POST /api/v1/apps` produces:
  `protocol: "mastodon"`, no owner. Use this where the *registration* is only
  setup; a test that is about the registration endpoint itself should still post
  to it, so the shape under test is the one that flow really creates.
  """
  def register_mastodon_app(attrs \\ %{}) do
    {:ok, app, _secret} =
      ApiAuth.create_mastodon_app(
        Map.merge(
          %{
            "name" => "Pocket Client",
            "redirect_uris" => ["org.example.client://oauth"],
            "registered_scopes" => ["read"]
          },
          attrs
        )
      )

    app
  end

  @doc """
  A Mastodon access token for `user`, or for `organization` acting through
  `user`, with both identities' switches turned on.

  Returns the plaintext token, which is the only form a client ever holds.
  """
  def mastodon_token(user, scopes, organization \\ nil) do
    allow_mastodon_clients(user)
    if organization, do: allow_mastodon_clients(organization)

    plaintext = "vutuv_at_" <> ApiAuth.random_token()
    app = insert(:oauth_app, user: nil, protocol: "mastodon", registered_scopes: scopes)

    insert(:api_token,
      user: user,
      app: app,
      organization: organization,
      kind: "access",
      name: nil,
      scopes: scopes,
      expires_at: nil,
      token_hash: ApiAuth.hash_token(plaintext)
    )

    plaintext
  end

  @doc "The technical subdomain the adapter is served on in test."
  def mastodon_host, do: "mastodon.localhost"

  @doc "Puts `conn` on a host that serves the adapter, carrying `token`."
  def mastodon_conn(conn, token) do
    conn
    |> Map.put(:host, mastodon_host())
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
  end

  @doc "Puts `conn` on the adapter's host without a token."
  def on_mastodon_host(conn), do: Map.put(conn, :host, mastodon_host())
end
