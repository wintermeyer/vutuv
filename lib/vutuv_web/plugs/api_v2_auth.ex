defmodule VutuvWeb.Plug.ApiV2Auth do
  @moduledoc """
  Bearer-token authentication and scope enforcement for `/api/2.0` (see
  `Vutuv.ApiAuth`).

  On success assigns `:current_user`, `:api_token` and `:api_scopes` and
  stamps the `X-RateLimit-*` headers; on failure halts with a problem+json
  401 (or 429 over the per-token limit). Every request verifies the token
  against the database — revocation and app suspension take effect on the
  next request, by design.

  Scope enforcement is **default-deny**: every `/api/2.0` route declares
  the scope it needs in its router assigns (`api_scope: "posts:write"`, or
  `:none` for the 404 catch-all), and this plug refuses to serve a route
  without that declaration — an endpoint can never ship unchecked because
  someone forgot a per-controller plug.
  """

  import Plug.Conn

  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.Scopes
  alias Vutuv.RateLimiter
  alias VutuvWeb.ApiV2.Problem

  @default_rate_limit {5_000, :timer.hours(1)}

  def init(opts), do: opts

  def call(conn, _opts) do
    case bearer_token(conn) do
      nil ->
        unauthorized(conn, "Send an Authorization: Bearer <token> header.")

      plaintext ->
        authenticate(conn, plaintext)
    end
  end

  defp authenticate(conn, plaintext) do
    with {:ok, token, user} <- ApiAuth.verify_token(plaintext),
         {:ok, remaining, limit} <- rate_check(token) do
      conn
      |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
      |> put_resp_header("x-ratelimit-remaining", Integer.to_string(remaining))
      |> assign(:current_user, user)
      |> assign(:api_token, token)
      |> assign(:api_scopes, token.scopes)
      |> enforce_scope()
    else
      {:error, :rate_limited} -> rate_limited(conn)
      {:error, reason} -> unauthorized(conn, detail_for(reason))
    end
  end

  defp enforce_scope(conn) do
    case conn.assigns[:api_scope] do
      :none ->
        conn

      scope when is_binary(scope) ->
        Scopes.valid?(scope) ||
          raise "the matched /api/2.0 route declares the unknown api_scope #{inspect(scope)}"

        if Scopes.granted?(conn.assigns.api_scopes, scope) do
          conn
        else
          Problem.send_problem(conn, 403, "Missing scope",
            detail:
              "This endpoint needs the \"#{scope}\" scope, which this token was not granted.",
            extra: %{required_scope: scope}
          )
        end

      nil ->
        # Default-deny: a route without a declared scope is a programming
        # error, not an open endpoint.
        raise "the matched /api/2.0 route declares no :api_scope assign"
    end
  end

  defp bearer_token(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2, trim: true),
         "bearer" <- String.downcase(scheme) do
      String.trim(token)
    else
      _other -> nil
    end
  end

  defp rate_check(token) do
    {limit, window_ms} = Application.get_env(:vutuv, :api_v2_rate_limit, @default_rate_limit)

    case RateLimiter.hit_remaining({:api_token, token.id}, limit, window_ms) do
      {:ok, remaining} -> {:ok, remaining, limit}
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  defp unauthorized(conn, detail) do
    Problem.send_problem(conn, 401, "Unauthorized",
      detail: detail,
      headers: [{"www-authenticate", ~s(Bearer realm="vutuv API", error="invalid_token")}]
    )
  end

  defp rate_limited(conn) do
    {_limit, window_ms} = Application.get_env(:vutuv, :api_v2_rate_limit, @default_rate_limit)

    Problem.send_problem(conn, 429, "Rate limit exceeded",
      detail: "This token is over its request limit. Wait and retry.",
      headers: [{"retry-after", Integer.to_string(div(window_ms, 1000))}]
    )
  end

  defp detail_for(:revoked), do: "This token has been revoked."
  defp detail_for(:expired), do: "This token has expired."

  defp detail_for(:app_suspended),
    do: "The application this token belongs to has been suspended."

  defp detail_for(:account_inactive),
    do: "The account this token belongs to is not available."

  defp detail_for(_invalid), do: "The bearer token is invalid."
end
