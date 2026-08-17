defmodule VutuvWeb.MastodonApi.AppController do
  @moduledoc "Mastodon's public, unattended OAuth application registration."

  use VutuvWeb, :controller

  alias Ecto.Changeset
  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.OAuth
  alias Vutuv.MastodonApi.Scopes
  alias Vutuv.MastodonApi.WebPush
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
  `GET /api/v1/apps/verify_credentials` — the app behind a `client_credentials`
  token, and the one thing such a token is for.

  Authenticated **here**, not by `Plug.MastodonApiAuth`: that plug resolves a
  member and every route behind it is member-scoped, which an app token has no
  business reaching. It reads `oauth_app_tokens` and nothing else, so a member's
  bearer token cannot identify an app either — the two credentials cannot be
  swapped in either direction, and that is the property, not a check somebody has
  to remember.

  The response deliberately carries **no** `client_id` and no secret: the client
  already holds both, and echoing a credential back to whoever presents a token
  is how one leaks into a log.
  """
  def verify_credentials(conn, _params) do
    case OAuth.verify_app_token(bearer_token(conn)) do
      nil -> conn |> put_status(401) |> json(%{error: "The access token is invalid"})
      app -> json(conn, application(app))
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _rest] -> String.trim(token)
      _absent -> nil
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
