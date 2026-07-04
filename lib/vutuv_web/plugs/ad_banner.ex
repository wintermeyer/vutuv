defmodule VutuvWeb.Plug.AdBanner do
  @moduledoc """
  Decides whether this request gets the ad banner (the strip between the top
  navigation and the content, see `Vutuv.Ads`) and enforces the frequency
  cap: at most one sighting per hour per session.

  The whole banner is gated by the global `:ads_enabled` switch
  (`Vutuv.Ads.enabled?/0`): with the ad system off nothing is ever assigned,
  so no banner serves anywhere.

  The cap counts **sightings, not attempts**: the plug only assigns
  `:ad_banner` here, and the `before_send` hook marks the hour as used only
  when the rendered page actually contains the banner (the `id="vutuv-ad"`
  marker). A redirect, a 404, an agent-format document or a LiveView page
  (whose layout renders from the socket, without conn assigns) therefore
  never burns the visitor's slot. Writing the session in `before_send`
  works because callbacks run last-registered-first, so the timestamp lands
  before `Plug.Session` serializes the cookie.

  The banner's ✕ control dismisses ads for the rest of the (Berlin) day:
  app.js writes a plain client-side cookie naming that day, and any request
  carrying today's value gets no banner at all. The cookie is unsigned on
  purpose - forging it only keeps ads away from yourself.

  GET only, never on the landing page `/` (the sign-up funnel stays ad-free),
  and not on `/ads` itself - a house ad above the page that sells ads would
  advertise advertising on the advertising page. It also stays off the account
  pages (`/:slug/edit` and `/:slug/settings/*`): those are focused, owner-only
  tasks where an ad is noise, not a place anyone is browsing.
  """

  import Plug.Conn

  alias VutuvWeb.Plug.AgentFormat

  @hour 3600
  # The banner's DOM id as rendered by the layout's ad_banner component.
  @marker ~s(id="vutuv-ad")
  # The dismissed-for-today cookie written by the ✕ (see app.js).
  @dismissed_cookie "vutuv_ad_dismissed"

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    conn = fetch_cookies(conn)

    if not Vutuv.Ads.enabled?() or agent_format?(conn) or landing_page?(conn) or
         booking_pages?(conn) or account_pages?(conn) or dismissed_today?(conn) or
         recently_seen?(conn) do
      conn
    else
      conn
      |> assign(:ad_banner, Vutuv.Ads.current_banner())
      |> register_before_send(&mark_seen/1)
    end
  end

  def call(conn, _opts), do: conn

  defp dismissed_today?(conn) do
    conn.req_cookies[@dismissed_cookie] == Date.to_iso8601(Vutuv.Ads.today())
  end

  defp agent_format?(conn), do: AgentFormat.agent_format?(conn)

  # The logged-out landing / sign-up page is the primary registration funnel:
  # keep it ad-free so the house ad doesn't compete with the sign-up hero.
  defp landing_page?(conn), do: conn.path_info == []

  defp booking_pages?(conn), do: conn.path_info |> List.first() == "ads"

  # The whole /settings scope (the user-agnostic editors) plus the old
  # /:slug/edit and /:slug/settings/* redirect stubs and the owner-only
  # /:slug/export corner (issue #841): focused, owner-only pages, not
  # somewhere a visitor is browsing. A deeper "edit" segment on a public
  # page (e.g. /:slug/links/:id/edit no longer exists, but the guard keys
  # on the first/second segment only) is unaffected.
  defp account_pages?(conn) do
    List.first(conn.path_info) == "settings" or
      Enum.at(conn.path_info, 1) in ["edit", "settings", "export"]
  end

  defp recently_seen?(conn) do
    case get_session(conn, :ad_seen_at) do
      seen_at when is_integer(seen_at) -> System.system_time(:second) - seen_at < @hour
      _other -> false
    end
  end

  defp mark_seen(conn) do
    if conn.status == 200 and banner_in_body?(conn) do
      put_session(conn, :ad_seen_at, System.system_time(:second))
    else
      conn
    end
  end

  defp banner_in_body?(%Plug.Conn{resp_body: body}) when not is_nil(body) do
    body |> IO.iodata_to_binary() |> String.contains?(@marker)
  end

  defp banner_in_body?(_conn), do: false
end
