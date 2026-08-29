defmodule VutuvWeb.Plug.HtmlOnly do
  @moduledoc """
  Refuses a format the page cannot render, with the 406 `plug :accepts,
  ["html"]` would have given — for the pages whose HTML is a LiveView.

  The `:browser` pipeline admits `application/activity+json` beside HTML so an
  ActivityPub fetch reaches the four URLs that answer one (the member and page
  profiles and their post permalinks, which branch on
  `VutuvWeb.FediverseController.ap_request?/1` — the raw header, not the
  negotiated format). Every other page of that pipeline has no such
  representation, and a LiveView has no template for the format either:
  `Phoenix.LiveView.Static` answers `{:safe, iodata}`, which `Plug.Conn.resp/3`
  cannot take as a body. That was a **500** on `/feed`, `/organizations`,
  `/search`, `/notifications` and every other page of the shape (issue #1776),
  while `application/ld+json` — never on the accept list — answered a clean 406
  all along.

  So the question is asked a second time, once per page shape rather than once
  per page: the router's `:html_only` pipeline covers the routed LiveViews (the
  two `live_session` blocks), `VutuvWeb.ControllerHelpers.render_live/3` the
  controllers that `live_render` their page.

  A request that already resolved to an **agent document** is left alone
  (`VutuvWeb.Plug.AgentFormat`): `/jobs.md` is served from
  `VutuvWeb.AgentDocs` by the controller and never renders the LiveView, so the
  URL extension decides, not the header the client happened to send with it.
  Dropping that exemption costs `/jobs.md` its Markdown (measured: 406), so it
  is load-bearing rather than defensive.

  The exemption used to be **wider than it reads**: a `.md` URL whose route is
  a LiveView that serves no document — `/notifications.md`, `/search.md`,
  `/bookmarks.json` — was waved through here and then rendered the LiveView for
  whatever format the client asked for, i.e. the same 500 this module exists to
  close. That was never this module's to narrow: `AgentFormat` now normalizes
  the `Accept` header on its extension path as well as its negotiation path
  (issue #1823), so by the time the exemption applies the header says
  `text/html` and there is no second format left to render for.
  """

  @behaviour Plug

  alias Phoenix.Controller
  alias VutuvWeb.Plug.AgentFormat

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    if AgentFormat.agent_format?(conn), do: conn, else: Controller.accepts(conn, ["html"])
  end
end
