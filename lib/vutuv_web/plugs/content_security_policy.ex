defmodule VutuvWeb.Plug.ContentSecurityPolicy do
  @moduledoc """
  The Content-Security-Policy header for every browser-pipeline response —
  the second line of defense should an XSS ever slip past the Markdown
  sanitizer: no external or inline scripts run, forms cannot be re-targeted
  off-site, nothing embeds the app.

  Everything the app serves is same-origin (scripts, styles, fonts, every
  image — avatars, covers, screenshots and post images are all stored and
  proxied locally; user Markdown may only inline-reference own attachments),
  so the policy is essentially `'self'` plus two documented exceptions:

    * `img-src data:` — components.css carries its icons as data URIs.
    * `style-src 'unsafe-inline'` — LiveView writes style attributes
      (upload progress, JS.show/hide transitions).

  `connect-src` names the websocket origin explicitly: not every browser
  matches `ws(s)://` against a plain `'self'`, and without it the LiveView
  socket cannot join. Derived per request from scheme/host/port, so dev
  (`ws://localhost:4000`) and prod (`wss://www.vutuv.de`) both come out
  right without configuration.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Plug.Conn.put_resp_header(conn, "content-security-policy", policy(conn))
  end

  defp policy(conn) do
    Enum.join(
      [
        "default-src 'self'",
        "img-src 'self' data:",
        "style-src 'self' 'unsafe-inline'",
        "connect-src 'self' #{ws_origin(conn)}",
        "font-src 'self' data:",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'self'",
        "frame-ancestors 'self'"
      ],
      "; "
    )
  end

  # ws://host[:port] for http, wss://host[:port] for https. The port rides
  # along only when non-standard (dev's :4000); the production 443 must not
  # appear (the public origin has no explicit port).
  defp ws_origin(conn) do
    scheme = if conn.scheme == :https, do: "wss", else: "ws"

    port =
      case {conn.scheme, conn.port} do
        {:http, 80} -> ""
        {:https, 443} -> ""
        {_, port} -> ":#{port}"
      end

    "#{scheme}://#{conn.host}#{port}"
  end
end
