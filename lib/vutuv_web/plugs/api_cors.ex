defmodule VutuvWeb.Plug.ApiCors do
  @moduledoc """
  CORS for the token-authenticated JSON API (`/api/2.0`).

  The API authenticates with bearer tokens, never cookies, so the wildcard
  `Access-Control-Allow-Origin: *` is safe and lets browser-based
  third-party apps call it directly. Preflight OPTIONS requests are
  answered here (204, no auth — browsers send them without the
  Authorization header), so this plug must run before the auth plug.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn =
      merge_resp_headers(conn, [
        {"access-control-allow-origin", "*"},
        {"access-control-expose-headers", "x-ratelimit-limit, x-ratelimit-remaining, retry-after"}
      ])

    if conn.method == "OPTIONS" do
      conn
      |> merge_resp_headers([
        {"access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS"},
        {"access-control-allow-headers", "authorization, content-type"},
        {"access-control-max-age", "86400"}
      ])
      |> send_resp(204, "")
      |> halt()
    else
      conn
    end
  end
end
