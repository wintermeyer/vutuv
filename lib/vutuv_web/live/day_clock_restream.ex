defmodule VutuvWeb.Live.DayClockRestream do
  @moduledoc """
  Shared handler body for the `Vutuv.DayClock` `:day_changed` tick.

  Three post-showing LiveViews keep a plain list of the entries currently on
  screen — the feed (`@entries` → `:posts`), notifications (`@items` →
  `:notifications`) and the saved hub (`@saved_posts` → `:posts`). Streams don't
  retain their data, so that list is kept only so the midnight tick can
  re-render each shown post / quoted-post stamp in place ("08:42 Uhr" ->
  "Gestern, 08:42 Uhr") when the Berlin calendar day rolls over.

  `restream/3` re-inserts every retained entry into its stream with
  `update_only: true`: LiveView refreshes each existing row where it sits and
  ignores any no longer on the client, so stale entries left in the list
  (deleted / pruned posts) are harmless: no re-insert, no reorder. Order and
  duplicates don't matter for the same reason.
  """

  import Phoenix.LiveView, only: [stream_insert: 4]

  @doc """
  Refresh every retained entry under `list_key` into the `stream_name` stream,
  updating existing rows in place. Returns the updated socket.
  """
  def restream(socket, list_key, stream_name) do
    Enum.reduce(socket.assigns[list_key], socket, fn entry, socket ->
      stream_insert(socket, stream_name, entry, update_only: true)
    end)
  end
end
