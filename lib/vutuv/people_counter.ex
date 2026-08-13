defmodule Vutuv.PeopleCounter do
  @moduledoc """
  Live, bottleneck-free "how many people are around this installation" counter —
  the figure in the middle of the top bar.

  It adds up **two** populations, and the reason it is one number is that a
  reader asking how big this place is does not care which side of the fence
  somebody stands on:

    * the confirmed **members** here (`Vutuv.Accounts.count_users/0`), and
    * the distinct remote **accounts** that follow a member, a page or a topic
      of this installation from the Fediverse
      (`Vutuv.Fediverse.distinct_follower_count/0`).

  **Nobody is counted twice.** `fediverse_followers` holds one row per (actor,
  followed thing), so an account subscribed to two members and three tags owns
  five rows and is one person — hence the distinct count over the actor address
  rather than a row count; and an actor on one of our own hosts is left out of
  it entirely, because such a person is already in the member half. What it
  cannot see is one human running two Mastodon accounts, or a member who also
  follows us from elsewhere: those are two accounts, and two is what it says.

  The work is split by cost, as it was when this only counted members:

    * The live figures live in a lock-free `:atomics` cell (slot 1 members,
      slot 2 Fediverse accounts) whose ref is kept in `:persistent_term`.
      `counts/0` (read on every page render, live and dead) and `increment/0`
      (every sign-up) are O(1) and touch neither a process mailbox nor the
      database, so any number of simultaneous sign-ups just race on one atomic
      add.

    * One GenServer owns the slow paths. It seeds both slots from the database
      at start-up, re-reads the authoritative member count on a long timer (so
      the value self-heals against deletions and out-of-band changes), re-reads
      the Fediverse head count on a shorter one, and broadcasts the current
      figures to subscribed LiveViews on a short timer — but only when they
      actually changed, so a burst coalesces into at most one broadcast per
      tick instead of a fan-out storm.

  The two halves move in deliberately different ways. A sign-up or a deletion
  ticks the member slot **at once** (`increment/0` / `decrement/0` from
  `Vutuv.Accounts`), because that event happens in this application. A remote
  Follow arrives in the inbox, where the interesting question is not "one more"
  but "is this account already counted somewhere else" — a question only the
  database can answer. Rather than teach eight write paths (three add, three
  remove, the pruner, an instance block) to ask it and risk one of them
  forgetting, the owner process re-reads the whole head count once a minute.
  So a new Fediverse follower shows up within a minute rather than instantly,
  and there is exactly one place that decides what the figure means.

  `VutuvWeb.ShellLive` subscribes and re-renders the top bar's pill on each
  `{:people_count, %{members:, fediverse:, total:}}` message, so the number
  ticks up while the page is open.
  """
  use GenServer

  alias Vutuv.Accounts
  alias Vutuv.Fediverse

  @pubsub Vutuv.PubSub
  @topic "people_count"
  @persistent_key {__MODULE__, :ref}

  # The two slots of the atomic cell.
  @members 1
  @fediverse 2
  @slots 2

  # How often the owner process broadcasts the live figures (coalescing a burst
  # of sign-ups into one message), how often it re-reads the authoritative
  # member count, and how often the Fediverse head count. All three are slow
  # paths; none of them runs per sign-up or per request.
  @broadcast_interval :timer.seconds(1)
  @reconcile_interval :timer.minutes(5)
  @fediverse_interval :timer.minutes(1)

  ## Client API — lock-free, no GenServer round trip

  @doc """
  The current figures: `%{members:, fediverse:, total:}`. Two O(1) reads of the
  atomic cell, so a page render can afford it.
  """
  def counts do
    case :persistent_term.get(@persistent_key, nil) do
      nil -> %{members: 0, fediverse: 0, total: 0}
      ref -> read(ref)
    end
  end

  @doc "The advertised people total — members plus Fediverse accounts."
  def count, do: counts().total

  @doc """
  Record one new member. A lock-free atomic increment, so it stays cheap and
  contention-free no matter how many sign-ups land at the same instant.
  """
  def increment do
    case :persistent_term.get(@persistent_key, nil) do
      nil -> :ok
      ref -> :atomics.add(ref, @members, 1)
    end

    :ok
  end

  @doc """
  Record one member leaving, the mirror of `increment/0`: an account deletion
  takes a confirmed member out of the advertised total, so the figure ticks back
  down at once instead of waiting up to five minutes for the next reconcile.
  Lock-free like its twin.
  """
  def decrement do
    case :persistent_term.get(@persistent_key, nil) do
      nil -> :ok
      ref -> subtract_one(ref)
    end

    :ok
  end

  # The cell is unsigned, so `:atomics.sub_get/3` wraps to the top of the 64-bit
  # range rather than returning a negative number. Zero is only reachable in the
  # sub-second before the first reconcile seeds the cell, but without this guard
  # one delete landing in that window would advertise eighteen quintillion
  # people until the next reconcile. Any result in the upper half of the range
  # is that wrap and never a real total.
  @wrapped_below_zero 0x8000_0000_0000_0000

  defp subtract_one(ref) do
    if :atomics.sub_get(ref, @members, 1) > @wrapped_below_zero,
      do: :atomics.put(ref, @members, 0)
  end

  @doc "Subscribe the calling process to live `{:people_count, counts}` updates."
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  defp read(ref) do
    members = :atomics.get(ref, @members)
    fediverse = :atomics.get(ref, @fediverse)

    %{members: members, fediverse: fediverse, total: members + fediverse}
  end

  ## Server

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    # `name: nil` (isolated test instances) starts the process unregistered.
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    ref = Keyword.get(opts, :ref) || :atomics.new(@slots, signed: false)

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
      fediverse_interval: Keyword.get(opts, :fediverse_interval, @fediverse_interval),
      reconcile?: Keyword.get(opts, :reconcile?, enabled?),
      broadcast?: Keyword.get(opts, :broadcast?, enabled?),
      last_broadcast: nil
    }

    # The singleton publishes its ref so the lock-free client functions can find
    # it. Isolated test instances pass `register?: false` to leave it alone.
    if Keyword.get(opts, :register?, true), do: :persistent_term.put(@persistent_key, ref)

    # Seed asynchronously (a 0ms reconcile) rather than running the counts
    # inline: a COUNT on a large table must not block the supervisor at boot.
    # The cell reads 0 for the sub-second until the first reconcile lands, then
    # the next broadcast corrects any page already open.
    if state.reconcile? do
      schedule(:reconcile, 0)
      schedule(:reconcile_fediverse, 0)
    end

    if state.broadcast?, do: schedule(:broadcast, state.broadcast_interval)

    {:ok, state}
  end

  @impl true
  def handle_info(:broadcast, state) do
    current = read(state.ref)

    state =
      if current == state.last_broadcast do
        state
      else
        Phoenix.PubSub.broadcast(@pubsub, state.topic, {:people_count, current})
        %{state | last_broadcast: current}
      end

    schedule(:broadcast, state.broadcast_interval)
    {:noreply, state}
  end

  def handle_info(:reconcile, state) do
    :atomics.put(state.ref, @members, Accounts.count_users())
    schedule(:reconcile, state.reconcile_interval)
    {:noreply, state}
  end

  def handle_info(:reconcile_fediverse, state) do
    :atomics.put(state.ref, @fediverse, Fediverse.distinct_follower_count())
    schedule(:reconcile_fediverse, state.fediverse_interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(message, interval), do: Process.send_after(self(), message, interval)

  defp enabled?, do: Application.get_env(:vutuv, :reconcile_people_count, true)
end
