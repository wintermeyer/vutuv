defmodule VutuvWeb.Live.RemoteCounts do
  @moduledoc """
  Makes the like and repost figures on a card from another network tick while a
  page is open (issue #1283).

  `VutuvWeb.PostLive.RemoteActionsComponent` draws those figures, and a
  LiveComponent has no process of its own — a subscription made inside one would
  land its messages in the host LiveView's `handle_info/2`, which the host never
  wrote. So the listening happens once **per page**, here, and the message is
  forwarded to the bar by component id.

  It is an `on_mount` hook rather than a copied `handle_info` clause in each
  host, because there are seven of them (the feed, the permalink conversation,
  the account page, the URL lookup, the tag timeline, the saved list, the remote
  post's own page) and a clause missing from one is invisible: the figures on
  that page simply never move. A host opts in with one line and handles nothing.

  Two properties worth keeping:

    * **One topic, filtered by delivery.** Every open page hears about every
      changed figure and `send_update/3` finds the bars that are actually on it;
      a component id that is not mounted is a debug log and nothing else. That is
      far cheaper than a subscription per rendered card on a feed page.
    * **Connected sockets only.** The dead render is thrown away the moment the
      socket connects, so subscribing for it would be a subscription nobody
      reads.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, send_update: 2]

  alias Vutuv.Fediverse
  alias VutuvWeb.PostLive.RemoteActionsComponent

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Fediverse.subscribe_counts()
      {:cont, attach_hook(socket, :remote_counts, :handle_info, &forward/2)}
    else
      {:cont, socket}
    end
  end

  defp forward({:fediverse_counts, kind, id, counts}, socket) do
    send_update(RemoteActionsComponent,
      id: RemoteActionsComponent.dom_id(kind, id),
      counts: counts
    )

    {:halt, socket}
  end

  defp forward(_other, socket), do: {:cont, socket}
end
