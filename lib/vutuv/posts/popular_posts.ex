defmodule Vutuv.Posts.PopularPosts do
  @moduledoc """
  Periodically cached candidate pool for the feed's "Vorschläge" rail.

  `Posts.discover_posts/2` used to answer the whole question per viewer, and
  it answered it up to three times: a ladder of tiers (recent strangers →
  strangers of any age → anyone recent), each one a fresh scan over posts
  joined to a like rollup, ranked one-per-author. But the expensive half of
  that question — *which public posts in this language were well received, one
  per author, best first* — has the same answer for every reader on the
  installation. Only the last mile is personal: not my own posts, nobody I
  muted or blocked, and people I do not follow ahead of people I do.

  So one GenServer owns the shared half, exactly the `Vutuv.Social.PopularUsers`
  and `Vutuv.Posts.TopPosters` deal: every few minutes it ranks each configured
  locale's pool into a `read_concurrency` ETS table, and a draw takes its
  candidates from the snapshot with no ranking scan at all. That matters more
  than a page-load figure suggests, because the rail is not only drawn on
  arrival: every open feed tab redraws it on a timer, so the old cost scaled
  with tabs left open, not with people reading.

  **The pool proposes; the database disposes.** A snapshot is minutes old, and
  in those minutes a post can be frozen, restricted, or its author suspended,
  deactivated or blocked by this very viewer. So the snapshot holds *candidate*
  ids only, and the draw re-applies the full anonymous visibility gate
  (`Posts.scope_visible/2`) plus the viewer's own exclusions to the handful it
  picked. That check is affordable precisely because it is bounded to a few
  hundred known ids instead of the posts table — which is the trade the whole
  design rests on. Staleness may therefore cost a reader a slightly out-of-date
  *suggestion*, never a post they were not allowed to see.

  When the snapshot cannot answer (application boot, an unconfigured locale,
  or tests — the refresh timer is off under
  `config :vutuv, :refresh_popular_posts, false`), `top/2` returns `:miss` and
  `discover_posts/2` transparently falls back to the live tier ladder, so
  behaviour is unchanged, only cheaper.
  """
  use GenServer

  @table __MODULE__
  # Deeper than the handful a card shows, and deeper than the 100 the draw
  # ranks: the per-viewer filter removes everyone the reader already follows,
  # and a member who follows every active author is exactly the case the
  # ladder's last tier exists for. A shallow pool would leave them an empty
  # rail — the one thing the tiers were built to prevent.
  @pool_size 500
  @refresh_interval :timer.minutes(10)

  @doc "How many posts per locale the snapshot ranks."
  def pool_size, do: @pool_size

  @doc "The ETS table the application-wide snapshot lives in."
  def default_table, do: @table

  @doc """
  The cached candidates for `locale`, best-liked first, as `{:ok, rows}` —
  each row a `%{id:, user_id:, inserted_at:}` — or `:miss` when the snapshot
  cannot answer (not seeded yet, table absent, or a locale it does not carry).
  """
  def top(locale, table \\ @table) do
    case :ets.lookup(table, {:pool, locale}) do
      [{{:pool, ^locale}, rows}] -> {:ok, rows}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Recompute the snapshot now (synchronous; used by tests)."
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh)

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    # `name: nil` (isolated test instances) starts the process unregistered.
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    table =
      :ets.new(Keyword.get(opts, :table, @table), [
        :named_table,
        :protected,
        read_concurrency: true
      ])

    interval = Keyword.get(opts, :refresh_interval, @refresh_interval)

    # The seed is a 0ms refresh rather than an inline query: the ranking scan
    # must not block the supervisor at boot. Until it lands, readers miss and
    # fall back to the tier ladder — exactly the pre-cache behaviour.
    if Keyword.get(opts, :refresh?, enabled?()), do: schedule(0)

    {:ok, %{table: table, interval: interval}}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    snapshot(state.table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    snapshot(state.table)
    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # One ranking query per configured locale, for the whole installation,
  # however many people are reading.
  defp snapshot(table) do
    for locale <- locales() do
      :ets.insert(table, {{:pool, locale}, Vutuv.Posts.compute_discover_pool(locale, @pool_size)})
    end
  end

  # The installation's configured locales, the same list the locale plug reads
  # (it lives under the Endpoint's config, not at the top level).
  defp locales do
    :vutuv
    |> Application.get_env(VutuvWeb.Endpoint, [])
    |> Keyword.get(:locales, ["en"])
  end

  defp schedule(interval), do: Process.send_after(self(), :refresh, interval)

  defp enabled?, do: Application.get_env(:vutuv, :refresh_popular_posts, true)
end
