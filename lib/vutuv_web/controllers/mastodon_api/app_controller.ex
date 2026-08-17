defmodule VutuvWeb.MastodonApi.AppController do
  @moduledoc "Mastodon's public, unattended OAuth application registration."

  use VutuvWeb, :controller

  alias Ecto.Changeset
  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.App
  alias Vutuv.ApiAuth.OAuth
  alias Vutuv.MastodonApi.Scopes
  alias Vutuv.MastodonApi.WebPush
  alias VutuvWeb.Plug.MastodonApiAuth
  alias VutuvWeb.RateLimit

  @registration_limit 20
  @registration_window :timer.hours(1)

  def create(conn, params) do
    with :ok <- registration_allowed?(conn),
         {:ok, scopes} <- Scopes.parse_registration(params["scopes"]),
         attrs <- app_attrs(params, scopes),
         {:ok, app, secret} <- ApiAuth.create_mastodon_app(attrs) do
      json(conn, credential_application(app, secret))
    else
      {:error, :rate_limited} ->
        conn |> put_status(429) |> json(%{error: "Too many application registrations"})

      {:error, :invalid_scope} ->
        validation_error(conn, "Scopes are invalid.")

      {:error, changeset} ->
        validation_error(conn, changeset_error(changeset))
    end
  end

  @doc """
  `GET /api/v1/apps/verify_credentials` — which app the presented credential
  belongs to.

  Authenticated **here**, not by `Plug.MastodonApiAuth`: that plug resolves a
  *member*, and every route behind it is member-scoped, which is exactly where an
  app-only credential has no business. This one endpoint is the reverse question,
  so it answers for **both** credentials, the way Mastodon's does — its
  documentation says the header may carry "a client credential or an access
  token", and a client checking which app its member token belongs to must not
  get a 401 here. The two are resolved apart (`oauth_app_tokens` through
  `OAuth.verify_app_token/1`, `api_tokens` through `ApiAuth.verify_token/1`, which
  applies every revocation, expiry and account check), so widening this endpoint
  does not widen anything else: an app token still cannot reach a member-scoped
  route, because it is not in the table that path reads.

  The response deliberately carries **no** `client_id` and no secret: the client
  already holds both, and echoing a credential back to whoever presents a token
  is how one leaks into a log.
  """
  def verify_credentials(conn, _params) do
    case resolve_app(MastodonApiAuth.bearer_token(conn)) do
      %App{} = app -> json(conn, application(app))
      nil -> conn |> put_status(401) |> json(%{error: "The access token is invalid"})
    end
  end

  defp resolve_app(nil), do: nil

  defp resolve_app(token) do
    case OAuth.verify_app_token(token) do
      %App{} = app -> app
      nil -> member_token_app(token)
    end
  end

  # A member's own token names its app too. Only a Mastodon-protocol one: a PAT
  # has no app at all, and a native `/api/2.0` token's app was never registered
  # through this surface.
  defp member_token_app(token) do
    case ApiAuth.verify_token(token) do
      {:ok, %{app: %App{protocol: "mastodon"} = app}, _user} -> app
      _no_app -> nil
    end
  end

  # Mastodon's Application entity, minus the credentials.
  defp application(app) do
    %{
      id: app.id,
      name: app.name,
      website: app.homepage_url,
      scopes: app.registered_scopes,
      redirect_uri: Enum.join(app.redirect_uris, "\n"),
      redirect_uris: app.redirect_uris,
      vapid_key: WebPush.public_key()
    }
  end

  defp registration_allowed?(conn) do
    case RateLimit.check(conn, :mastodon_app_registration, nil,
           limit: @registration_limit,
           window_ms: @registration_window
         ) do
      :ok -> :ok
      :rate_limited -> {:error, :rate_limited}
    end
  end

  defp app_attrs(params, scopes) do
    %{
      "name" => params["client_name"],
      "homepage_url" => params["website"],
      "redirect_uris" => normalize_redirect_uris(params["redirect_uris"]),
      "registered_scopes" => scopes
    }
  end

  defp normalize_redirect_uris(uris) when is_list(uris), do: uris

  defp normalize_redirect_uris(uris) when is_binary(uris) do
    String.split(uris, ~r/\R/, trim: true)
  end

  defp normalize_redirect_uris(_missing), do: []

  defp credential_application(app, secret) do
    %{
      id: app.id,
      name: app.name,
      website: app.homepage_url,
      scopes: app.registered_scopes,
      redirect_uri: Enum.join(app.redirect_uris, "\n"),
      redirect_uris: app.redirect_uris,
      client_id: app.client_id,
      client_secret: secret,
      client_secret_expires_at: 0
    }
  end

  defp validation_error(conn, message) do
    conn |> put_status(422) |> json(%{error: "Validation failed: " <> message})
  end

  defp changeset_error(changeset) do
    changeset
    |> Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end
end
