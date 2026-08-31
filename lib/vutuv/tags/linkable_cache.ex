defmodule Vutuv.Tags.LinkableCache do
  @moduledoc """
  The short-lived memo in front of `Vutuv.Tags.linkable_slugs/1` — "does this
  written `#hashtag` name a topic whose page is worth a click".

  That question is asked **once per rendered post body**, which on a feed page
  is once per card, and answering it is a `UNION ALL` of two multi-join
  subqueries wrapped in a `DISTINCT`. Measured on a copy of production
  (2026-08-31), a body carrying a hashtag cost **3.4 ms and one query** against
  **0.2 ms and none** for a body without one, and a single `/feed` arrival ran
  that query twenty-one times for sixty-four distinct hashtags. The answer does
  not depend on who is reading — the member gate (`account_confirmed_row/1`,
  not hidden) and the post gate (`Posts.visible_tagged_posts_query/0`) are both
  the anonymous public view — so one process's answer is every process's
  answer, and the table is global rather than per-viewer.

  Like `Vutuv.Posts.TopPosters` and `Vutuv.SocialFeed.Cache`: one GenServer owns
  a `read_concurrency` ETS table, readers hit it directly and never call the
  process, and **any miss is a live query** — an absent table (this process is
  off in the test env, or boot has not finished) answers "everything is
  missing", so behaviour is unchanged and only cheaper.

  **Negative answers are cached too**, and they are the half that pays: nearly
  every hashtag on a cached remote post names no topic here, so remembering
  only the hits would leave the expensive path running for the common case.

  ## What the staleness costs

  An entry lives #{div(60_000, 1000)}s. Within that window a tag minted a moment
  ago stays plain text, and a tag whose last member and last post went away
  keeps its link. Both heal on their own and neither is wrong enough to pay a
  query per card for: the window is one minute, not one hour, precisely so that
  a member writing a brand-new hashtag sees it become a link while they are
  still looking at the page.

  `name:` and `table:` are injectable so a test can run an isolated instance
  (the app-wide one is off under `config :vutuv, :linkable_tag_cache, false`).
  """

  use GenServer

  @table __MODULE__
  @ttl :timer.seconds(60)
  @sweep_interval :timer.seconds(30)

  @doc """
  Splits `keys` (folded `MatchKey`s) into `{known, missing}` — `known` maps a
  key to the slug its link points at, and a key remembered as naming nothing is
  in **neither** list, since it is answered rather than missing.

  A caller-side ETS read. An absent table answers `{%{}, keys}`, so the caller
  runs its ordinary query.
  """
  def fetch(keys, table \\ @table) when is_list(keys) do
    now = System.monotonic_time(:millisecond)
    Enum.reduce(keys, {%{}, []}, &take(table, &1, now, &2))
  rescue
    ArgumentError -> {%{}, keys}
  end

  # One key's three outcomes: remembered as naming nothing (answered, so it
  # joins neither list), remembered as naming a topic, or not remembered.
  defp take(table, key, now, {known, missing}) do
    case :ets.lookup(table, key) do
      [{^key, nil, expires_at}] when expires_at > now -> {known, missing}
      [{^key, target, expires_at}] when expires_at > now -> {Map.put(known, key, target), missing}
      _absent_or_expired -> {known, [key | missing]}
    end
  end

  @doc """
  Remembers what a live query answered: every key in `asked` that `found` does
  not carry named nothing, and is stored as such.

  `found` may hold keys nobody asked for — a tag is indexed under both its
  folded name and its folded slug (`Vutuv.Tags.index_by_match_keys/1`), so a
  lookup by one spelling answers for the other — and those are kept, since the
  next body may well write it the other way.
  """
  def put(asked, found, table \\ @table) when is_list(asked) and is_map(found) do
    expires_at = System.monotonic_time(:millisecond) + @ttl

    rows =
      asked
      |> Enum.reduce(found, &Map.put_new(&2, &1, nil))
      |> Enum.map(fn {key, target} -> {key, target, expires_at} end)

    :ets.insert(table, rows)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Ages every entry out on the spot (tests).

  The stamp is read back from the clock rather than set to zero:
  `System.monotonic_time/1` has an arbitrary origin and is routinely
  **negative**, so a literal `0` is a stamp comfortably in the future on a
  freshly booted machine and would expire nothing.
  """
  def expire_all(table \\ @table) do
    past = System.monotonic_time(:millisecond) - 1

    table
    |> :ets.tab2list()
    |> Enum.map(fn {key, target, _expires_at} -> {key, target, past} end)
    |> then(&:ets.insert(table, &1))

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "How long an entry is served for, in milliseconds."
  def ttl, do: @ttl

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)

    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:sweep, %{table: table} = state) do
    now = System.monotonic_time(:millisecond)
    # Expired rows only; `:"$3"` is the expiry stamp.
    :ets.select_delete(table, [{{:_, :_, :"$3"}, [{:"=<", :"$3", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
