defmodule Vutuv.Accounts.MemberCounter do
  @moduledoc """
  Live, bottleneck-free "number of members" counter behind the landing page.

  The sign-up page shows the exact member total and ticks it up in real time as
  people register. Doing that naively — a `SELECT count(*)` on every page view,
  or one per sign-up so we can broadcast the new total — would hammer the
  database exactly when traffic spikes. Instead the work is split by cost:

    * The live total lives in a lock-free `:atomics` cell whose ref is kept in
      `:persistent_term`. `count/0` (read on every landing-page render) and
      `increment/0` (called on every sign-up) are O(1) and touch neither a
      process mailbox nor the database, so any number of simultaneous sign-ups
      just race on one atomic add — there is no single process to serialize
      behind and nothing to block on.

    * One GenServer owns the slow paths. It seeds the cell from the database
      once at start-up, re-reads the authoritative count on a long timer (so the
      value self-heals against deletions and any out-of-band changes), and on a
      short timer broadcasts the current value to subscribed LiveViews — but
      only when it actually changed. A burst of sign-ups therefore coalesces
      into at most one broadcast per tick instead of a fan-out storm.

  `VutuvWeb.MemberCountLive` (embedded in the landing page) subscribes and
  re-renders the member-count pill on each `{:member_count, n}` message.
  """
  use GenServer

  @pubsub Vutuv.PubSub
  @topic "member_count"
  @persistent_key {__MODULE__, :ref}

  # How often the owner process broadcasts the live value (coalescing a burst of
  # sign-ups into one message) and how often it re-reads the authoritative count
  # from the database. Both are slow paths; neither runs per sign-up or request.
  @broadcast_interval :timer.seconds(1)
  @reconcile_interval :timer.minutes(5)

  ## Client API — lock-free, no GenServer round trip

  @doc "The current member total. An O(1) read of the atomic cell."
  def count do
    case :persistent_term.get(@persistent_key, nil) do
      nil -> 0
      ref -> :atomics.get(ref, 1)
    end
  end

  @doc """
  Record one new member. A lock-free atomic increment, so it stays cheap and
  contention-free no matter how many sign-ups land at the same instant.
  """
  def increment do
    case :persistent_term.get(@persistent_key, nil) do
      nil -> :ok
      ref -> :atomics.add(ref, 1, 1)
    end

    :ok
  end

  @doc "Subscribe the calling process to live `{:member_count, n}` updates."
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  ## Server

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    # `name: nil` (isolated test instances) starts the process unregistered.
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    ref = Keyword.get(opts, :ref) || :atomics.new(1, signed: false)

    # `enabled?` defaults both background timers off in tests (config flag), so
    # the application-wide singleton is a passive holder of the cell there and
    # never touches the DB it doesn't own nor broadcasts a stray value into a
    # LiveView test. Isolated test instances opt back in explicitly.
    enabled? = enabled?()

    state = %{
      ref: ref,
      topic: Keyword.get(opts, :topic, @topic),
      broadcast_interval: Keyword.get(opts, :broadcast_interval, @broadcast_interval),
      reconcile_interval: Keyword.get(opts, :reconcile_interval, @reconcile_interval),
      reconcile?: Keyword.get(opts, :reconcile?, enabled?),
      broadcast?: Keyword.get(opts, :broadcast?, enabled?),
      last_broadcast: nil
    }

    # The singleton publishes its ref so the lock-free client functions can find
    # it. Isolated test instances pass `register?: false` to leave it alone.
    if Keyword.get(opts, :register?, true), do: :persistent_term.put(@persistent_key, ref)

    # Seed asynchronously (a 0ms reconcile) rather than running `count_users/0`
    # inline: a COUNT on a large table must not block the supervisor at boot.
    # The cell reads 0 for the sub-second until the first reconcile lands, then
    # the next broadcast corrects any page already open.
    if state.reconcile?, do: schedule(:reconcile, 0)
    if state.broadcast?, do: schedule(:broadcast, state.broadcast_interval)

    {:ok, state}
  end

  @impl true
  def handle_info(:broadcast, state) do
    current = :atomics.get(state.ref, 1)

    state =
      if current == state.last_broadcast do
        state
      else
        Phoenix.PubSub.broadcast(@pubsub, state.topic, {:member_count, current})
        %{state | last_broadcast: current}
      end

    schedule(:broadcast, state.broadcast_interval)
    {:noreply, state}
  end

  def handle_info(:reconcile, state) do
    :atomics.put(state.ref, 1, Vutuv.Accounts.count_users())
    schedule(:reconcile, state.reconcile_interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(message, interval), do: Process.send_after(self(), message, interval)

  defp enabled?, do: Application.get_env(:vutuv, :reconcile_member_count, true)
end
