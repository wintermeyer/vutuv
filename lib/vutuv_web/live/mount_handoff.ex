defmodule VutuvWeb.Live.MountHandoff do
  @moduledoc """
  The single-use **dead-render → socket-mount handoff** for the expensive
  LiveView pages (the profile and the feed).

  Every LiveView visit computes its data twice: once for the HTML the visitor
  sees immediately (the dead render, in the request process) and once when the
  websocket connects and `mount/3` runs again in a fresh process. The two runs
  happen within a second or two of each other and compute identical data —
  ~50 queries each on the profile. This module lets the dead render pass its
  finished work to the connected mount instead: the dead mount `stash/4`es the
  assigns it computed, the connected mount `take/2`s them and skips the
  reload.

  It is deliberately **not a cache** — it is a baton passed exactly once:

    * **Single-use.** `take/2` consumes the entry (`:ets.take/2`), so a later
      reconnect (network blip, deploy) finds nothing and full-loads. No entry
      is ever served twice.
    * **Keyed by the authenticated viewer.** Both sides derive the key from
      their own server-side authentication (`Vutuv.Sessions` token → user id),
      never from anything the client sent, so one viewer can never take
      another's entry. Anonymous visitors are never stashed for — most
      anonymous dead renders are crawlers whose socket never connects.
    * **Short-lived.** Entries expire after #{div(15_000, 1000)}s (a sweeper
      deletes leftovers), so an unclaimed stash — closed tab, crawler —
      evaporates and the staleness window is bounded by the time between the
      HTML render and the socket connect.
    * **Fail closed.** Any miss — expired, consumed, wrong viewer, table not
      up — answers `:error` and the caller runs its normal full load. The
      handoff is a fast path, never a requirement.

  What a hit costs in freshness: changes landing in the sub-second gap between
  the two renders are not re-read at connect (today they are). Both pages
  subscribe to their PubSub topics at connect, so anything that matters
  announces itself and heals the snapshot; the trade buys back an entire page
  load per visit.
  """

  use GenServer

  @table __MODULE__
  @ttl_ms 15_000
  @sweep_ms 10_000

  ## Client API

  @doc """
  Stores `payload` for the connected mount of `subject` by the same viewer.
  A nil viewer (anonymous visitor) is a no-op — see the moduledoc. `ttl_ms`
  is overridable for tests only.
  """
  def stash(viewer_id, subject, payload, ttl_ms \\ @ttl_ms)

  def stash(viewer_id, subject, payload, ttl_ms) when is_binary(viewer_id) do
    :ets.insert(@table, {{viewer_id, subject}, payload, now_ms() + ttl_ms})
    :ok
  rescue
    # Table not up (a script without the app tree): the dead render simply
    # leaves nothing behind and the connected mount full-loads.
    ArgumentError -> :ok
  end

  def stash(_viewer_id, _subject, _payload, _ttl_ms), do: :ok

  @doc """
  Takes (and consumes) the stashed payload for `{viewer_id, subject}`.
  `:error` for anything but a fresh hit by the same viewer.
  """
  def take(viewer_id, subject) when is_binary(viewer_id) do
    case :ets.take(@table, {viewer_id, subject}) do
      [{_key, payload, expires_at}] ->
        if now_ms() < expires_at, do: {:ok, payload}, else: :error

      [] ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  def take(_viewer_id, _subject), do: :error

  # Monotonic on purpose: TTL is a duration, not a wall-clock moment, so a
  # clock adjustment can neither extend nor expire an entry.
  defp now_ms, do: System.monotonic_time(:millisecond)

  ## Table owner + sweeper

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now_ms()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
