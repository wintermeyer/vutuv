defmodule VutuvWeb.Plug.MastodonApiGate do
  @moduledoc """
  Installation switch and security-header boundary for the Mastodon client API.

  The router already limits these routes to the `mastodon.` host. Keeping the
  installation flag here makes a disabled adapter indistinguishable from one
  that is not installed at all.
  """

  import Plug.Conn

  alias Vutuv.MastodonApi

  def init(opts), do: opts

  def call(conn, _opts) do
    if MastodonApi.enabled?() and String.downcase(conn.host) == MastodonApi.api_host() do
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
