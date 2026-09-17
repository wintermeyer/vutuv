defmodule VutuvWeb.AdServing do
  @moduledoc """
  Decides, per request, whether a page gets the daily text ad, records the
  sighting once the page has gone out, and owns how that decision travels to
  the page's LiveView.

  Only the two pages that carry the ad ask: a profile (`UserController`) and
  the feed (`NewsfeedController`). Both are LiveViews rendered by their
  controller. `serve/1` puts the banner on the conn, which the disconnected
  render takes as it is; `session/1` is what the controller merges into the
  mount session, and `banner_from_session/2` is how `VutuvWeb.Live.AdSlot`
  reads it back on connect. That session is replayed unchanged on every
  rejoin, so it carries facts that never change while the page is open: which
  banner, and when it was served. The card's lifetime is counted from that
  moment, so a reconnect cannot bring back a card whose time is up.

  The two frequency rules (`Vutuv.Ads.eligible?/3`), fed from the server for a
  member and from the browser for a visitor without an account:

    * **At most one ad an hour.** A member's is `users.ad_seen_at`, shared by
      every device; a visitor's is the session.
    * **The ✕ ends ads for the day.** A member's is `users.ads_dismissed_on`;
      every browser also keeps the day in the cookie `vutuv_ad_dismissed`
      (written by the `AdSlot` hook), which is all a visitor has. The cookie is
      unsigned on purpose: forging it only keeps ads away from yourself.

  The hour is taken in a `before_send` hook, and only for a page that is
  actually sent with status 200. Callbacks run last-registered-first, so the
  session write lands before `Plug.Session` serializes the cookie.

  No ad while the one-time welcome questions float over the page
  (`VutuvWeb.Plug.WelcomeModal`): the backdrop would hide it and it would
  still take the hour.
  """

  import Plug.Conn

  alias Vutuv.Accounts.User
  alias Vutuv.Ads

  @dismissed_cookie "vutuv_ad_dismissed"
  # How long a card stays up, counted from the request that served it.
  @lifetime 120

  @doc """
  Hands today's banner to the page in `conn` (the `:ad_banner` assign) when
  the visitor may see one, and registers the hook that records the sighting.
  """
  def serve(%Plug.Conn{} = conn) do
    conn = fetch_cookies(conn)

    if Ads.enabled?() and is_nil(conn.assigns[:welcome_modal]) and eligible?(conn) do
      conn
      |> assign(:ad_banner, Ads.current_banner())
      |> assign(:ad_served_at, System.system_time(:second))
      |> register_before_send(&record_sighting/1)
    else
      conn
    end
  end

  defp eligible?(conn) do
    user = conn.assigns[:current_user]
    days = Enum.reject([cookie_day(conn), user && user.ads_dismissed_on], &is_nil/1)

    Ads.eligible?(seen_at(conn, user), Enum.max(days, Date, fn -> nil end))
  end

  defp seen_at(_conn, %User{ad_seen_at: seen_at}), do: seen_at

  defp seen_at(conn, nil) do
    case get_session(conn, :ad_seen_at) do
      unix when is_integer(unix) -> DateTime.from_unix!(unix)
      _other -> nil
    end
  end

  defp cookie_day(conn) do
    case Date.from_iso8601(conn.req_cookies[@dismissed_cookie] || "") do
      {:ok, day} -> day
      {:error, _reason} -> nil
    end
  end

  defp record_sighting(%Plug.Conn{status: 200} = conn) do
    case conn.assigns[:current_user] do
      %User{} = user ->
        Ads.record_sighting(user, conn.assigns.ad_banner)
        conn

      nil ->
        put_session(conn, :ad_seen_at, conn.assigns.ad_served_at)
    end
  end

  defp record_sighting(conn), do: conn

  @doc """
  The mount-session entries for the ad `serve/1` chose, to merge into what the
  controller hands its LiveView: the banner (`"house"` or the ad's id) and the
  second it was served. Empty when the page shows no ad.
  """
  def session(%Plug.Conn{assigns: %{ad_banner: banner, ad_served_at: served_at}}) do
    %{"ad_slot" => banner_ref(banner), "ad_served_at" => served_at}
  end

  def session(%Plug.Conn{}), do: %{}

  defp banner_ref({:ad, ad}), do: ad.id
  defp banner_ref(:house), do: "house"

  @doc """
  The banner a connecting page shows, with the milliseconds it has left, or
  nil: no ad was served, its time is up, or the ad may no longer serve (see
  `Vutuv.Ads.todays_ad/1`).
  """
  def banner_from_session(session, now \\ System.system_time(:second))

  def banner_from_session(%{"ad_slot" => ref, "ad_served_at" => served_at}, now)
      when is_binary(ref) and is_integer(served_at) do
    left = served_at + @lifetime - now

    with true <- left > 0 and Ads.enabled?(),
         banner when not is_nil(banner) <- banner_from_ref(ref) do
      {banner, left * 1000}
    else
      _gone -> nil
    end
  end

  def banner_from_session(_session, _now), do: nil

  defp banner_from_ref("house"), do: :house

  defp banner_from_ref(id) do
    case Ads.todays_ad(id) do
      nil -> nil
      ad -> {:ad, ad}
    end
  end
end
