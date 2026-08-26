defmodule VutuvWeb.Plug.AgentDocRoute do
  @moduledoc """
  Serves a page's **agent-format siblings** from a router pipeline, so the HTML
  half of that URL can be a plain `live` route (issue #1731).

  Every public page here is also `.md` / `.txt` / `.json` / `.xml` (and the
  profile `.vcf`) at the same URL, and until now that alone decided how the
  page was routed: negotiation is `VutuvWeb.AgentDocs.respond/2`, which needs a
  conn, so the page got a controller in front of it and the controller
  `live_render`ed the LiveView. That is a reasonable local decision with one
  expensive consequence — **a route that is not a `live` route cannot be in a
  `live_session`**, and `<.link navigate>` only patches within one session. So
  the feed, where members spend their time, could not be reached without
  rebuilding the whole document: stylesheet, socket, shell and all.

  This plug separates the format from the page. `VutuvWeb.Plug.AgentFormat`
  already runs in the endpoint and has already recorded which format the
  request asks for; this plug reads that answer inside the pipeline, **after**
  the session and auth plugs have run, and either

    * answers the document itself and `halt`s — the browser pipeline's own
      plugs decided the viewer, exactly as they did for the controller; or
    * assigns the `<link rel="alternate">` list (`put_html_alternates/2`) and
      lets the request fall through to the `live` route.

  The `:doc` option is `{Module, :function}`, called as `fun(conn, format)`; it
  must send the response. `:allowed` is the format list this page publishes,
  and it is required rather than defaulted: an extension outside the list
  resolves to `:html`, and `AgentFormat`'s `before_send` guard then turns that
  answer into a 404 — which is the intended behaviour, but only if the list is
  the page's real one.

  Use it in a pipeline scoped to the single route it belongs to. It is a
  pipeline plug, so everything else in that scope would otherwise pay the
  negotiation too.

  Two things the **second** page to use this will want, deliberately not built
  for the first. An `:html` hook, because the feed's HTML branch is only
  `put_html_alternates/2` while the profile's also sets `rel="me"`, the
  ActivityPub alternate and a robots header. And a way to stop spending one
  named `pipeline` per page — `pipeline` cannot take arguments, so page N needs
  pipeline N until the plug reads its configuration from the route's own
  `:metadata` instead. Neither is worth an unused option today; both are worth
  knowing about before a third page copies the pipeline.
  """

  @behaviour Plug

  import Plug.Conn, only: [halt: 1]

  alias VutuvWeb.AgentDocs

  @impl Plug
  def init(opts) do
    %{doc: Keyword.fetch!(opts, :doc), allowed: Keyword.fetch!(opts, :allowed)}
  end

  @impl Plug
  def call(conn, %{doc: {module, fun}, allowed: allowed}) do
    case AgentDocs.negotiate(conn, allowed) do
      :html -> AgentDocs.put_html_alternates(conn, allowed)
      format -> halt(apply(module, fun, [conn, format]))
    end
  end
end
