defmodule VutuvWeb.NewsfeedController do
  @moduledoc """
  The signed-in member's newsfeed (`/feed`). The HTML page is the LiveView
  `VutuvWeb.PostLive.Feed`, `live_render`ed here so the controller stays the
  entry point and can negotiate the **agent-format siblings** —
  `/feed.md/.txt/.json/.xml` (`VutuvWeb.AgentDocs.FeedDoc`), the viewer's
  timeline in another format. (Named NewsfeedController, not FeedController,
  which already serves the RSS feeds.)

  Unlike every other agent-format page these docs are **not** the anonymous
  public view: the feed is per-viewer and login-only. So an agent-format
  request without a signed-in viewer is a plain 404 (a private feed has no
  anonymous document and a `.md` URL must never serve HTML), and the doc is
  sent `private, no-store` + `noindex/noai` so a shared cache can never hand
  one member's feed to another.
  """

  use VutuvWeb, :controller

  alias Vutuv.Posts
  alias Vutuv.Prefs
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.FeedDoc
  alias VutuvWeb.ApiV2
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.PostLive.Feed

  def index(conn, params) do
    case AgentDocs.negotiate(conn) do
      :html -> show_html(conn, params)
      format -> send_feed_doc(conn, format, params)
    end
  end

  # The LiveView brings the `:app` layout (chrome + the socket assigns) itself,
  # so drop the controller's to avoid rendering it twice — the root layout (the
  # document <head>, with the agent-format alternates) still applies. The feed
  # is outside the `live_session`, so its session values are passed explicitly
  # (mirrors VutuvWeb.UserController.show).
  #
  # `?day=` and `?cal=` are the feed calendar's state (issue: time travel). The
  # LiveView is `live_render`ed rather than routed, so it has no
  # `handle_params/3` to read them itself — the controller is the only side
  # that sees the query string, and it hands the two values on through the
  # session map. They are display state, not identity: that map is signed but
  # **not encrypted**, so nothing that decides who the viewer is may ever
  # travel this way.
  defp show_html(conn, params) do
    conn
    |> AgentDocs.put_html_alternates()
    |> ControllerHelpers.render_live(Feed, %{
      "cal_day" => params["day"],
      "cal_open" => params["cal"]
    })
  end

  defp send_feed_doc(conn, format, params) do
    case conn.assigns[:current_user] do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      viewer ->
        # A foreign/expired `?cursor=` falls back to the first page rather than
        # erroring: the worst case is re-showing the latest posts.
        cursor = ApiV2.cursor_or_nil(params)

        # One page of the document is one arrival on the HTML page — the
        # member's own `:feed_page_size` — and `?limit=` overrides it, the same
        # knob every other machine-readable listing here answers to. The default
        # follows the member so an agent inherits a sensible length without
        # asking; the parameter is what keeps the document from changing size
        # under a caller because somebody tapped a chip in a browser tab.
        #
        # The size is all the two share: the document is deliberately the WHOLE
        # feed, with no source filter, since it carries none of the switches the
        # member has over there and narrowing it by one they cannot see here
        # would leave an agent no way to ask for the rest.
        #
        # Capped at what a caller is allowed to ask for, because a default is
        # not a licence: `page_limit/2` clamps an explicit `?limit=` to 100 and
        # would otherwise let a member on 250 build a bigger document by
        # standing still than any agent can request. `?cursor=` carries the rest.
        limit = ApiV2.page_limit(params, min(Prefs.feed_page_size(viewer), 100))
        page = Posts.feed_page(viewer, limit: limit, cursor: cursor)
        AgentDocs.send_doc(conn, format, FeedDoc.build(viewer, page), cache: "private, no-store")
    end
  end
end
