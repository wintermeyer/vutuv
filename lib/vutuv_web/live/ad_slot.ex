defmodule VutuvWeb.Live.AdSlot do
  @moduledoc """
  The daily text ad on a LiveView page that carries it, a profile and the feed.

      on_mount(VutuvWeb.Live.AdSlot)

  `@ad_banner` is what the request chose (`VutuvWeb.AdServing`). The
  disconnected render takes it straight from the conn. The connected mount
  reads it from the mount session and does not ask the frequency rules again:
  the request has already taken the visitor's hour, so asking now would hide
  the very ad it just counted.

  The card goes by itself once its lifetime, counted from the request that
  served it, is over; a reconnect after that shows no card at all. The ✕
  (`"dismiss-ad"`) takes it away for the rest of the Berlin day: on the server
  for a member (`Vutuv.Ads.dismiss_today/1`), and in the browser's day cookie
  for everyone, which the `AdSlot` hook writes before the event is sent.
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Vutuv.Ads
  alias VutuvWeb.AdServing

  def on_mount(:default, _params, session, socket) do
    socket =
      socket
      |> assign_banner(session)
      |> attach_hook(:ad_slot_event, :handle_event, &handle_event/3)
      |> attach_hook(:ad_slot_info, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  defp assign_banner(socket, session) do
    if connected?(socket) do
      case AdServing.banner_from_session(session) do
        {banner, left_ms} ->
          Process.send_after(self(), {__MODULE__, :expired}, left_ms)
          assign(socket, :ad_banner, banner)

        nil ->
          assign(socket, :ad_banner, nil)
      end
    else
      # The disconnected render inherits the conn's assign when there is one.
      assign_new(socket, :ad_banner, fn -> nil end)
    end
  end

  defp handle_event("dismiss-ad", _params, socket) do
    if user = socket.assigns[:current_user], do: Ads.dismiss_today(user)
    {:halt, assign(socket, :ad_banner, nil)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({__MODULE__, :expired}, socket), do: {:halt, assign(socket, :ad_banner, nil)}
  defp handle_info(_message, socket), do: {:cont, socket}
end
