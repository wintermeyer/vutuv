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

  import Phoenix.LiveView.Controller, only: [live_render: 3]

  alias Vutuv.Posts
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.FeedDoc
  alias VutuvWeb.ApiV2
  alias VutuvWeb.ControllerHelpers

  # Mirrors VutuvWeb.PostLive.Feed's @page_size, so the doc's first page matches
  # what the HTML page loads.
  @page_size 20

  def index(conn, params) do
    case AgentDocs.negotiate(conn) do
      :html -> show_html(conn)
      format -> send_feed_doc(conn, format, params)
    end
  end

  # The LiveView brings the `:app` layout (chrome + the socket assigns) itself,
  # so drop the controller's to avoid rendering it twice — the root layout (the
  # document <head>, with the agent-format alternates) still applies. The feed
  # is outside the `live_session`, so its session values are passed explicitly
  # (mirrors VutuvWeb.UserController.show).
  defp show_html(conn) do
    conn
    |> AgentDocs.put_html_alternates()
    |> put_layout(html: false)
    |> live_render(VutuvWeb.PostLive.Feed, session: ControllerHelpers.live_render_session(conn))
  end

  defp send_feed_doc(conn, format, params) do
    case conn.assigns[:current_user] do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      viewer ->
        # A foreign/expired `?cursor=` falls back to the first page rather than
        # erroring: the worst case is re-showing the latest posts.
        cursor = ApiV2.cursor_or_nil(params)

        page = Posts.feed_page(viewer, limit: @page_size, cursor: cursor)
        AgentDocs.send_doc(conn, format, FeedDoc.build(viewer, page), cache: "private, no-store")
    end
  end
end
