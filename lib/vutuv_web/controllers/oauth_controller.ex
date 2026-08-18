defmodule VutuvWeb.OauthController do
  @moduledoc """
  The OAuth 2 authorization server's HTTP face (the flow logic lives in
  `Vutuv.ApiAuth.OAuth`).

  `GET /oauth/authorize` renders the consent screen (after a PIN login
  round trip if needed — the request URL rides in the session). The POST
  is CSRF-protected like every browser form and re-validates the request
  before minting the code, so nothing tampered survives the round trip.

  Both legs re-stamp the CSP so `form-action` names the app's registered
  redirect URI: the site's blanket `form-action 'self'` is enforced on the
  redirect this endpoint answers with, and would otherwise leave the member
  staring at the consent screen with a minted code they never receive. See
  `VutuvWeb.Plug.ContentSecurityPolicy`.

  `POST /oauth/token` and `POST /oauth/revoke` are machine endpoints
  (form-encoded in, JSON out, no session/CSRF). Client/redirect problems
  never redirect — an authorize endpoint that redirects on a bad
  redirect_uri is an open redirector.
  """

  use VutuvWeb, :controller

  require Logger

  alias Vutuv.ApiAuth.OAuth
  alias Vutuv.ApiAuth.UserAgent
  alias Vutuv.MastodonApi.Access
  alias VutuvWeb.Plug.ContentSecurityPolicy
  alias VutuvWeb.RateLimit

  @oob_redirect "urn:ietf:wg:oauth:2.0:oob"

  # ── Consent (browser pipeline) ──

  def authorize(conn, params) do
    case OAuth.validate_authorize(params) do
      {:ok, request} ->
        if conn.assigns[:current_user] do
          identities = identities(conn.assigns.current_user, request)

          # The consent screen owns the form, so its policy is the one the
          # browser checks the POST's redirect against.
          conn
          |> ContentSecurityPolicy.allow_form_action(request.redirect_uri)
          |> render("authorize.html",
            request: request,
            params: params,
            identities: identities,
            consent_scopes: consent_scopes(request, identities),
            consent_nonce: OAuth.new_consent_nonce()
          )
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
        # Belt and braces: the consent screen's policy is what a browser
        # enforces here, but a client that re-POSTs this endpoint from a page
        # of its own gets the same permission from the response itself.
        conn
        |> ContentSecurityPolicy.allow_form_action(request.redirect_uri)
        |> decide(user, request, decision)

      _invalid_or_logged_out ->
        conn
        |> put_status(400)
        |> render("error.html", reason: :invalid_request)
    end
  end

  # A phone client resubmitted this form about a hundred times from a single
  # loaded page, up to eight times a second, and each submission minted its own
  # authorization code (issue #1561). Nothing of ours resubmits it, so this does
  # not chase that client's bug — it saves the wasted round trips and tells a
  # runaway client that something is wrong. What makes those repeats harmless is
  # `OAuth.approve/4`, which answers one consent with one code however often it
  # arrives; this bounds what a client can spend getting there.
  #
  # The ceiling sits far above anything a person does, because it must never
  # touch a working login: nobody presses Allow ten times in a minute. The guard
  # lives inside the "allow" clause rather than beside it, so "only a consent is
  # charged" is true by position — denying mints nothing, and charging it would
  # let a stream of refusals block a genuine consent afterwards.
  @consent_limit 10
  @consent_window :timer.minutes(1)

  defp decide(conn, user, request, "allow") do
    if within_consent_budget?(user, request) do
      mint_code(conn, user, request)
    else
      log_runaway(conn, user, request)
      conn |> put_status(429) |> render("error.html", reason: :too_many_requests)
    end
  end

  defp decide(conn, _user, request, _deny) do
    if request.redirect_uri == @oob_redirect,
      do:
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_status(403)
        |> text("access_denied"),
      else: redirect(conn, external: callback_url(request, error: "access_denied"))
  end

  # The half of issue #1561 nobody could answer: *which* client resubmits. The
  # browser's User-Agent reaches only the web server's access log, where nobody
  # is looking while it happens — and by the time the report arrives, the log
  # has rotated. Spending this budget is the definition of a runaway client, so
  # it is the one place where naming it costs nothing, and every installation
  # then finds the answer in its own log instead of ours. The app is named
  # rather than the member: what is wanted here is the client, not who they are.
  #
  # One line per member, app and minute, through a bucket of its own: the client
  # this exists to name sent a hundred requests in one, and a hundred identical
  # lines is how a log stops being read.
  #
  # `error`, not `warning`, and that is the whole point of the line. Production
  # runs the logger at `:error` (`config/prod.exs`), so the first version of
  # this diagnostic was discarded by the one installation that had the question
  # — while its test passed, because the test env logs from `:warning` down. An
  # installation can now raise the bar with `LOG_LEVEL`, but a diagnostic must
  # not depend on somebody having done that beforehand: this is also the level
  # the member sees, since the same event answers their login with a 429.
  defp log_runaway(conn, user, request) do
    if RateLimit.check(nil, :oauth_consent_report, user.id <> ":" <> request.app.id,
         limit: 1,
         window_ms: @consent_window
       ) == :ok do
      Logger.error(
        "oauth: consent budget spent, app=#{request.app.name} " <>
          "user_agent=#{UserAgent.capture(conn) || "(none sent)"}"
      )
    end
  end

  defp mint_code(conn, user, request) do
    case OAuth.approve(
           user,
           request,
           conn.params["identity"],
           conn.params["consent_nonce"]
         ) do
      {:ok, code} ->
        if request.redirect_uri == @oob_redirect,
          do: conn |> put_resp_header("cache-control", "no-store") |> text(code),
          else: redirect(conn, external: callback_url(request, code: code))

      {:error, _reason} ->
        conn |> put_status(403) |> render("error.html", reason: :forbidden)
    end
  end

  # `nil` instead of the conn skips the per-IP bucket on purpose, the way the
  # limiter documents for an authenticated event: only a signed-in member reaches
  # this, so the member+app identity is the real key. Passing the conn would put
  # every app in one per-IP bucket, and a client looping on one app would then
  # block the member from connecting a different one.
  #
  # The identity is a binary, not a tuple: the limiter hashes it through
  # `to_string/1`, which raises on a tuple.
  defp within_consent_budget?(user, request) do
    RateLimit.check(nil, :oauth_consent, user.id <> ":" <> request.app.id,
      limit: @consent_limit,
      window_ms: @consent_window
    ) == :ok
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

  defp identities(user, %{app: %{protocol: "mastodon"}, scopes: scopes}),
    do: Access.identities(user, scopes)

  defp identities(user, request), do: [%{value: "person", subject: user, scopes: request.scopes}]

  defp consent_scopes(_request, [%{scopes: scopes}]), do: scopes
  defp consent_scopes(request, _identities), do: request.scopes

  # ── The token endpoints (machine pipeline, no session/CSRF) ──

  def token(conn, %{"grant_type" => "authorization_code"} = params) do
    token_response(conn, OAuth.exchange(params, UserAgent.capture(conn)))
  end

  def token(conn, %{"grant_type" => "refresh_token"} = params) do
    token_response(conn, OAuth.refresh(params, UserAgent.capture(conn)))
  end

  # RFC 6749 §4.4, which Mastodon's token endpoint answers: a token for the app
  # itself, with no member behind it. A client asks for one right after
  # registering and before it opens a browser, so refusing it stops setup dead —
  # Ivory on a real phone never reached the consent screen. Only Mastodon apps
  # get it (`OAuth.client_credentials/1` says why); everybody else falls through
  # to the `unsupported_grant_type` below, unchanged.
  def token(conn, %{"grant_type" => "client_credentials"} = params) do
    token_response(conn, OAuth.client_credentials(params))
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

  # A native client asking for `client_credentials`: the grant exists but is not
  # offered to it, which is exactly what this code says. 400 per RFC 6749 §5.2.
  defp token_response(conn, {:error, :unsupported_grant_type}) do
    oauth_error(conn, 400, "unsupported_grant_type")
  end

  # A client asking for more than its app registered. Naming it beats
  # `invalid_grant`, which would send the client looking at its credentials.
  defp token_response(conn, {:error, :invalid_scope}) do
    oauth_error(conn, 400, "invalid_scope")
  end

  defp token_response(conn, {:error, _reason}), do: oauth_error(conn, 400, "invalid_grant")

  defp oauth_error(conn, status, code) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(%{error: code})
  end
end
