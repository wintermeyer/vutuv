defmodule VutuvWeb.Live.AdSlot do
  @moduledoc """
  The daily text ad on a LiveView page that carries it, a profile and the feed.

      on_mount(VutuvWeb.Live.AdSlot)

  `@ad_slot` is what the request chose (`VutuvWeb.AdServing`): a map with the
  banner and the second it was served, or nil. The disconnected render takes it
  straight from the conn. The connected mount reads it from the mount session
  and does not ask the frequency rules again, since the request already did.

  The card's `AdSlot` hook reports four things:

    * `"ad-seen"`: the card was at least half in view for the first time. For
      a member this takes the hour and counts the sighting
      (`Vutuv.Ads.record_sighting/3`); when another tab took the hour first,
      this card goes. A visitor has no hour.
    * `"ad-click"`: its title link was followed. A booked ad counts one click
      per page, and a visitor's view counts once per page too (a member's
      counts with the sighting).
    * `"ad-expired"`: its countdown ran out, which only counts visible time.
    * `"dismiss-ad"`, the ✕: the card goes, and a member sees no ads until
      Berlin midnight (`Vutuv.Ads.dismiss_today/1`).
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, put_private: 3]

  alias Vutuv.Accounts.User
  alias Vutuv.Ads
  alias VutuvWeb.AdServing

  def on_mount(:default, _params, session, socket) do
    socket =
      socket
      |> assign_slot(session)
      |> attach_hook(:ad_slot, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  defp assign_slot(socket, session) do
    if connected?(socket) do
      assign(socket, :ad_slot, AdServing.slot_from_session(session))
    else
      # The disconnected render inherits the conn's assign when there is one.
      assign_new(socket, :ad_slot, fn -> nil end)
    end
  end

  defp handle_event("ad-seen", _params, socket) do
    case socket.assigns do
      %{ad_slot: %{banner: banner}, current_user: %User{} = user} ->
        case Ads.record_sighting(user, banner) do
          :ok -> {:halt, socket}
          :capped -> {:halt, assign(socket, :ad_slot, nil)}
        end

      %{ad_slot: %{banner: banner}} ->
        {:halt, count_once(socket, :view, fn -> Ads.count_view(banner) end)}

      _gone ->
        {:halt, socket}
    end
  end

  defp handle_event("ad-click", _params, socket) do
    case socket.assigns.ad_slot do
      %{banner: banner} -> {:halt, count_once(socket, :click, fn -> Ads.count_click(banner) end)}
      nil -> {:halt, socket}
    end
  end

  defp handle_event("ad-expired", _params, socket), do: {:halt, assign(socket, :ad_slot, nil)}

  # Both copies of the card may send this; the day is written once.
  defp handle_event("dismiss-ad", _params, socket) do
    with %{} <- socket.assigns.ad_slot, %User{} = user <- socket.assigns[:current_user] do
      Ads.dismiss_today(user)
    end

    {:halt, assign(socket, :ad_slot, nil)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # A page counts one view and one click at most, however often its card
  # reports: the hook sends each once, and a replayed event must not add up.
  defp count_once(socket, what, count) do
    if socket.private[{:ad_counted, what}] do
      socket
    else
      count.()
      put_private(socket, {:ad_counted, what}, true)
    end
  end
end
