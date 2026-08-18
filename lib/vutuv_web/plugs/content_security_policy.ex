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
  (`ws://localhost:4000`) and prod (`wss://vutuv.de`) both come out
  right without configuration.

  ## `form-action` and the OAuth consent screen

  `form-action` is checked against **every hop of the submission, redirects
  included** (Chrome and WebKit both do this; the enforcing policy is the one
  of the document that owns the form). The OAuth consent screen is the one
  page here whose form is *supposed* to end up somewhere else: `POST
  /oauth/authorize` answers 302 to the client's registered `redirect_uri` —
  `ivory://…` for a phone client, an off-origin `https://` callback for a web
  one — and under a bare `form-action 'self'` the browser refuses that hop.
  The failure is silent and reads as a dead button: the POST *does* reach the
  server, a code *is* minted, and the member is left looking at the consent
  screen with no token, which is what an Ivory user reported.

  So `allow_form_action/2` lets that one response widen the directive to the
  exact redirect target. It is only ever called with a URI
  `Vutuv.ApiAuth.OAuth.validate_authorize/1` has already matched against the
  app's registered `redirect_uris`, so this names a destination the server was
  going to redirect to anyway — never anything read straight off the query
  string.

  That makes widening the exception rather than the pattern: it works here only
  because the destination is registered and known while the page renders. The
  other two submissions bound for another site cannot say that, so they leave
  the header alone and answer with a page, letting an ordinary navigation make
  the hop (`VutuvWeb.OutboundHTML`, issue #1569). Prefer that shape for
  anything new; reach for `allow_form_action/2` only when the destination is
  pinned in advance.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Plug.Conn.put_resp_header(conn, "content-security-policy", policy(conn, []))
  end

  @doc """
  Re-stamps this response's policy with `redirect_uri` added to `form-action`,
  so a form on this page may submit to an endpoint that redirects there.

  For the OAuth consent screen, see the moduledoc. Pass the **validated**
  redirect URI (the one matched against the app's registered list), never a
  raw parameter. An unusable URI (no scheme) leaves the policy alone.
  """
  def allow_form_action(conn, redirect_uri) do
    case form_action_source(redirect_uri) do
      nil -> conn
      source -> Plug.Conn.put_resp_header(conn, "content-security-policy", policy(conn, [source]))
    end
  end

  # What CSP's own `host-source` grammar can spell: letters, digits, `-`, `.`.
  # `URI.parse/1` validates nothing, so `https://evil.example.org;script-src
  # 'unsafe-inline'/cb` — which app registration accepts, and registration is
  # public — comes back with that whole run as its "host". Spliced into the
  # header that is a second directive of the caller's choosing, so a host we
  # cannot spell widens nothing. The scheme needs no such check: a scheme
  # outside the grammar makes `URI.parse/1` answer `nil` (measured), which the
  # first clause below turns away.
  @host ~r/^[a-z0-9.\-]+$/i

  @doc """
  The CSP source expression that permits a form submission to end at `uri`,
  or `nil` for a target no source expression can name.

  `http(s)` gets the exact origin, which is as narrow as CSP can express and
  is where narrowness is worth having. Anything else is a native app's own
  scheme (`ivory://oauth-callback`, `com.example.app:/cb`) whose shape varies
  too much to pin down as a host-source, so it gets the scheme-source
  (`ivory:`) — a scheme registered to that one app.

  Two targets deliberately widen nothing. A `urn:` is a name and not a place:
  the out-of-band flow (`urn:ietf:wg:oauth:2.0:oob`) prints the code on our
  own page instead of redirecting, so there is no hop to permit. And a host
  outside CSP's grammar — an intranet name with an underscore, an IPv6
  literal, or anything carrying a `;` — has no source expression at all, so
  the strict policy stands and the redirect stays blocked.
  """
  def form_action_source(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: nil} ->
        nil

      %URI{scheme: scheme, host: host, port: port} when scheme in ["http", "https"] ->
        if is_binary(host) and Regex.match?(@host, host), do: origin(scheme, host, port)

      %URI{scheme: "urn"} ->
        nil

      %URI{scheme: scheme} ->
        scheme <> ":"
    end
  end

  def form_action_source(_uri), do: nil

  # A source with no port matches only the scheme's default port, so 443/80
  # must stay off and a dev callback's :4000 must ride along — which is what
  # `URI.to_string/1` does with a port, for `ws`/`wss` as much as `http(s)`.
  defp origin(scheme, host, port),
    do: URI.to_string(%URI{scheme: scheme, host: host, port: port})

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

  # The static directives never vary, so they are pre-joined once at compile time
  # into the two halves that bracket the per-request `connect-src` (which keeps
  # its historical 4th position, so the emitted header stays byte-identical to
  # the old per-request `Enum.join/2` of all nine directives).
  @prefix_directives [
    "default-src 'self'",
    "img-src 'self' data:",
    "style-src 'self' 'unsafe-inline'"
  ]

  # `form-action` sits between these two halves so the one response that widens
  # it (the OAuth consent screen) can rebuild that directive alone. With no
  # extra sources the emitted header stays byte-identical to the old one.
  @suffix_before ["font-src 'self' data:", "object-src 'none'", "base-uri 'self'"]
  @suffix_after ["frame-ancestors 'self'"]

  @static_prefix Enum.join(@prefix_directives, "; ")
  @static_suffix_before Enum.join(@suffix_before, "; ")
  @static_suffix_after Enum.join(@suffix_after, "; ")

  defp policy(conn, form_action_sources) do
    directives =
      @static_prefix <>
        "; connect-src 'self' " <>
        ws_origin(conn) <>
        "; " <>
        @static_suffix_before <>
        "; " <> form_action(form_action_sources) <> "; " <> @static_suffix_after

    maybe_allow_eval(directives)
  end

  defp form_action(sources),
    do: Enum.reduce(sources, "form-action 'self'", &(&2 <> " " <> &1))

  defp maybe_allow_eval(directives) do
    if @allow_eval do
      "script-src 'self' 'unsafe-eval'; " <> directives
    else
      directives
    end
  end

  # ws://host[:port] for http, wss://host[:port] for https. The port rides
  # along only when non-standard (dev's :4000); the production 443 must not
  # appear (the public origin has no explicit port).
  defp ws_origin(conn) do
    origin(if(conn.scheme == :https, do: "wss", else: "ws"), conn.host, conn.port)
  end
end
