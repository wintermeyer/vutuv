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

  # DEV-ONLY escape hatch. When true we add `script-src 'self' 'unsafe-eval'` so
  # Tidewave's `browser_eval` tool works locally: it injects JS and runs it with
  # `eval()` to drive and inspect the page (e.g. measuring element geometry to
  # confirm a mobile layout isn't clipped). Under the strict `default-src 'self'`
  # (no `script-src`) the browser refuses `eval` and the tool throws "Refused to
  # evaluate a string as JavaScript".
  #
  # WHY it is gated: `'unsafe-eval'` weakens the CSP, our second line of defense
  # behind the Markdown sanitizer, so it MUST NEVER reach production. It is read
  # with `compile_env`, and only config/dev.exs sets it, so a prod/test build
  # (which never loads dev.exs) bakes in `false` and emits no `script-src` at all.
  #
  # TO UNDO / DISABLE: delete (or set to false) the `config :vutuv, csp: [...]`
  # line in config/dev.exs and recompile. Nothing else reads this flag, and the
  # policy falls back to the strict `default-src 'self'`. A regression test
  # (content_security_policy_test.exs) keeps eval out of the non-dev policy.
  @allow_eval Application.compile_env(:vutuv, [:csp, :allow_eval], false)

  defp policy(conn) do
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
    ]
    |> maybe_allow_eval()
    |> Enum.join("; ")
  end

  defp maybe_allow_eval(directives) do
    if @allow_eval do
      ["script-src 'self' 'unsafe-eval'" | directives]
    else
      directives
    end
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
