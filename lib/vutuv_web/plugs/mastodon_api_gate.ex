defmodule VutuvWeb.Plug.MastodonApiGate do
  @moduledoc """
  Installation switch and security-header boundary for the Mastodon client API.

  This plug is the **only** thing that decides which hosts serve the adapter:
  the routes carry no host constraint, so `client_host?/1` here is the whole
  boundary — the technical subdomain and the main host both answer, and anything
  else 404s. Keeping the installation flag in the same place makes a disabled
  adapter indistinguishable from one that is not installed at all.
  """

  import Plug.Conn

  alias Vutuv.MastodonApi

  def init(opts), do: opts

  def call(conn, _opts) do
    if MastodonApi.enabled?() and MastodonApi.client_host?(conn.host) do
      merge_resp_headers(conn, [
        {"content-security-policy", "default-src 'none'; frame-ancestors 'none'"},
        {"referrer-policy", "no-referrer"},
        {"x-content-type-options", "nosniff"},
        {"x-frame-options", "DENY"}
      ])
    else
      conn |> send_resp(404, "") |> halt()
    end
  end
end
