defmodule VutuvWeb.Live.DayClockRestream do
  @moduledoc """
  Shared handler body for the `Vutuv.DayClock` `:day_changed` tick.

  Two post-showing LiveViews keep a plain list of the entries currently on
  screen — the feed (`@entries` → `:posts`) and the saved hub (`@saved_posts` →
  `:posts`). Streams don't retain their data, so that list is kept only so the
  tick can re-render each shown post / quoted-post stamp in place ("08:42 Uhr"
  -> "Gestern, 08:42 Uhr") when the reader's calendar day rolls over.

  **Only when it has rolled over.** The clock ticks on every whole UTC hour,
  because that is when *some* reader's midnight falls, and every stamp on a card
  (`VutuvWeb.UI.post_time/1`) is worded by the reader's day and nothing finer.
  So each host keeps the day its stream was last rendered for, and a tick that
  finds the same day re-sends nothing; re-inserting every card 23 times a day
  for nothing is what this replaced.

  The re-insert uses `update_only: true`: LiveView refreshes each existing row
  where it sits and ignores any no longer on the client, so stale entries left
  in the list (deleted / pruned posts) are harmless: no re-insert, no reorder.
  Order and duplicates don't matter for the same reason.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream_insert: 4]

  alias Vutuv.ViewerClock

  @doc """
  When the reader's day is no longer the one under `day_key`, stamps the new
  day there and refreshes every retained entry under `list_key` into the
  `stream_name` stream in place. Otherwise returns the socket untouched.
  """
  def restream(socket, list_key, stream_name, day_key) do
    today = ViewerClock.today()

    if socket.assigns[day_key] == today do
      socket
    else
      Enum.reduce(
        socket.assigns[list_key],
        assign(socket, day_key, today),
        &stream_insert(&2, stream_name, &1, update_only: true)
      )
    end
  end
end
