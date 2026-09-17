defmodule VutuvWeb.AdServing do
  @moduledoc """
  Decides, per request, whether a page gets the daily text ad, and owns how
  that decision travels to the page's LiveView.

  Only the two pages that carry the ad ask: a profile (`UserController`) and
  the feed (`NewsfeedController`). Both are LiveViews rendered by their
  controller. `serve/1` puts the slot (the banner and the second it was served)
  on the conn, which the disconnected render takes as it is; `session/1` is
  what the controller merges into the mount session, and `slot_from_session/2`
  is how `VutuvWeb.Live.AdSlot` reads it back on connect. That session is
  replayed unchanged on every rejoin, so it carries only facts that never
  change while the page is open.

  Sending a page takes nothing. What counts is a card that was seen, and the
  `AdSlot` hook reports that. The two frequency rules
  (`Vutuv.Ads.eligible?/3`) then read:

    * **At most one ad an hour.** A member's hour is `users.ad_seen_at`, on the
      server and shared by every device. A visitor without an account has the
      cookie `vutuv_ad_seen` (the second their browser showed a card), since a
      socket cannot write the session.
    * **The ✕ ends ads for the day.** A member's is `users.ads_dismissed_on`;
      every browser also keeps the day in the cookie `vutuv_ad_dismissed`,
      which is all a visitor has.

  Both cookies are written by the hook and unsigned on purpose: forging one
  only keeps ads away from yourself.

  No ad while the one-time welcome questions float over the page
  (`VutuvWeb.Plug.WelcomeModal`): the backdrop would hide it.
  """

  import Plug.Conn

  alias Vutuv.Accounts.User
  alias Vutuv.Ads

  @dismissed_cookie "vutuv_ad_dismissed"
  @seen_cookie "vutuv_ad_seen"

  @doc """
  Hands today's ad to the page in `conn` (the `:ad_slot` assign) when the
  visitor may see one.
  """
  def serve(%Plug.Conn{} = conn) do
    conn = fetch_cookies(conn)

    if Ads.enabled?() and is_nil(conn.assigns[:welcome_modal]) and eligible?(conn) do
      assign(conn, :ad_slot, %{
        banner: Ads.current_banner(),
        served_at: System.system_time(:second)
      })
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
    with value when is_binary(value) <- conn.req_cookies[@seen_cookie],
         {unix, ""} <- Integer.parse(value),
         {:ok, seen_at} <- DateTime.from_unix(unix) do
      seen_at
    else
      _unreadable -> nil
    end
  end

  defp cookie_day(conn) do
    case Date.from_iso8601(conn.req_cookies[@dismissed_cookie] || "") do
      {:ok, day} -> day
      {:error, _reason} -> nil
    end
  end

  @doc """
  The mount-session entries for the slot `serve/1` chose, to merge into what
  the controller hands its LiveView. Empty when the page shows no ad.
  """
  def session(%Plug.Conn{assigns: %{ad_slot: %{banner: banner, served_at: served_at}}}) do
    %{"ad_slot" => banner_ref(banner), "ad_served_at" => served_at}
  end

  def session(%Plug.Conn{}), do: %{}

  @doc """
  The slot a connecting page shows, or nil: no ad was served, the request lies
  an hour back or more (the hour that card belonged to is over), or the ad may
  no longer serve (see `Vutuv.Ads.todays_ad/1`).
  """
  def slot_from_session(session, now \\ System.system_time(:second))

  def slot_from_session(%{"ad_slot" => ref, "ad_served_at" => served_at}, now)
      when is_binary(ref) and is_integer(served_at) do
    with true <- Ads.enabled?(),
         true <- Ads.within_the_hour?(DateTime.from_unix!(served_at), DateTime.from_unix!(now)),
         banner when not is_nil(banner) <- banner_from_ref(ref) do
      %{banner: banner, served_at: served_at}
    else
      _gone -> nil
    end
  end

  def slot_from_session(_session, _now), do: nil

  @doc """
  What names one served card in the browser: it keeps the countdown and the
  sighting of that card for the page load, and a new page load is a new card.
  """
  def key(%{banner: banner, served_at: served_at}), do: "#{served_at}:#{banner_ref(banner)}"

  defp banner_ref({:ad, ad}), do: ad.id
  defp banner_ref(:house), do: "house"

  defp banner_from_ref("house"), do: :house

  defp banner_from_ref(id) do
    case Ads.todays_ad(id) do
      nil -> nil
      ad -> {:ad, ad}
    end
  end
end
