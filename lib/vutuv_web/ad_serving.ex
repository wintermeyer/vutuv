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

  The three rules (`Vutuv.Ads.eligible?/2`) are a member's, kept on the server
  and shared by every device:

    * **Nothing for the first two weeks**, counted from `users.inserted_at`.
    * **At most one ad an hour**, `users.ad_seen_at`. Sending a page takes
      nothing; the hour starts when the `AdSlot` hook reports a card as seen.
    * **The ✕ ends ads for the day**, `users.ads_dismissed_on`.

  A visitor without an account sees the ad on every profile. Nothing about them
  is kept, neither on the server nor in a cookie, so their ✕ closes only the
  card in front of them.

  No ad while the one-time welcome questions float over the page
  (`VutuvWeb.Plug.WelcomeModal`): the backdrop would hide it.
  """

  import Plug.Conn

  alias Vutuv.Ads

  @doc """
  Hands today's ad to the page in `conn` (the `:ad_slot` assign) when the
  visitor may see one.
  """
  def serve(%Plug.Conn{} = conn) do
    if Ads.enabled?() and is_nil(conn.assigns[:welcome_modal]) and
         Ads.eligible?(conn.assigns[:current_user]) do
      assign(conn, :ad_slot, %{
        banner: Ads.current_banner(),
        served_at: System.system_time(:second)
      })
    else
      conn
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
