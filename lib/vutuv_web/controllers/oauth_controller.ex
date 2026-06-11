defmodule VutuvWeb.OauthController do
  @moduledoc """
  The OAuth 2 authorization server's HTTP face (the flow logic lives in
  `Vutuv.ApiAuth.OAuth`).

  `GET /oauth/authorize` renders the consent screen (after a PIN login
  round trip if needed — the request URL rides in the session). The POST
  is CSRF-protected like every browser form and re-validates the request
  before minting the code, so nothing tampered survives the round trip.

  `POST /oauth/token` and `POST /oauth/revoke` are machine endpoints
  (form-encoded in, JSON out, no session/CSRF). Client/redirect problems
  never redirect — an authorize endpoint that redirects on a bad
  redirect_uri is an open redirector.
  """

  use VutuvWeb, :controller

  alias Vutuv.ApiAuth.OAuth

  # ── Consent (browser pipeline) ──

  def authorize(conn, params) do
    case OAuth.validate_authorize(params) do
      {:ok, request} ->
        if conn.assigns[:current_user] do
          render(conn, "authorize.html", request: request, params: params)
        else
          conn
          |> put_session(:login_return_to, current_path(conn))
          |> put_flash(
            :info,
            gettext("Please log in to connect %{app} with your account.", app: request.app.name)
          )
          |> redirect(to: ~p"/login")
        end

      {:error, reason} ->
        # Render, never redirect: for client/redirect errors a redirect
        # would be dangerous, for the rest it is just unnecessary.
        conn
        |> put_status(400)
        |> render("error.html", reason: reason)
    end
  end

  def approve(conn, %{"decision" => decision} = params) do
    user = conn.assigns[:current_user]

    case user && OAuth.validate_authorize(params) do
      {:ok, request} ->
        decide(conn, user, request, decision)

      _invalid_or_logged_out ->
        conn
        |> put_status(400)
        |> render("error.html", reason: :invalid_request)
    end
  end

  defp decide(conn, user, request, "allow") do
    {:ok, code} = OAuth.approve(user, request)
    redirect(conn, external: callback_url(request, code: code))
  end

  defp decide(conn, _user, request, _deny) do
    redirect(conn, external: callback_url(request, error: "access_denied"))
  end

  # The exact registered redirect URI plus our query params (state echoes
  # back when the app sent one).
  defp callback_url(request, query_params) do
    uri = URI.parse(request.redirect_uri)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.merge(Map.new(query_params, fn {k, v} -> {to_string(k), v} end))
      |> maybe_put_state(request.state)
      |> URI.encode_query()

    URI.to_string(%{uri | query: query})
  end

  defp maybe_put_state(query, nil), do: query
  defp maybe_put_state(query, state), do: Map.put(query, "state", state)

  # ── The token endpoints (machine pipeline, no session/CSRF) ──

  def token(conn, %{"grant_type" => "authorization_code"} = params) do
    token_response(conn, OAuth.exchange(params))
  end

  def token(conn, %{"grant_type" => "refresh_token"} = params) do
    token_response(conn, OAuth.refresh(params))
  end

  def token(conn, _params), do: oauth_error(conn, 400, "unsupported_grant_type")

  def revoke(conn, params) do
    case OAuth.revoke(params) do
      :ok -> conn |> put_resp_header("cache-control", "no-store") |> send_resp(200, "")
      {:error, _reason} -> oauth_error(conn, 401, "invalid_client")
    end
  end

  defp token_response(conn, {:ok, tokens}) do
    # RFC 6749 §5.1: token responses must not be cached.
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(tokens)
  end

  defp token_response(conn, {:error, reason}) when reason in [:invalid_client, :app_suspended] do
    oauth_error(conn, 401, "invalid_client")
  end

  defp token_response(conn, {:error, _reason}), do: oauth_error(conn, 400, "invalid_grant")

  defp oauth_error(conn, status, code) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(%{error: code})
  end
end
