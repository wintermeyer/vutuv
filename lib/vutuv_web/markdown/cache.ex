defmodule VutuvWeb.Markdown.Cache do
  @moduledoc """
  The memo in front of `VutuvWeb.Markdown.render_post/3` and `render_remote/1` —
  the Markdown-to-HTML pipeline every post body goes through on its way to a
  card.

  That pipeline is not cheap: escaping, autolinking, Earmark, HtmlSanitizeEx,
  code fences, mentions and hashtags. Measured on a copy of production
  (2026-09-03), stubbing it out entirely took a `/feed` arrival from **22.1 ms
  to 15.9 ms** — a quarter of the whole render, for text that had not changed.

  And the same body really is rendered again and again. A single `/feed`
  arrival renders each of its cards **twice** on its own: once for the HTML
  document and once more when the socket connects and the LiveView builds its
  join payload. On top of that a popular post sits in many members' feeds, on
  its author's profile, on a tag timeline and on its permalink, all of them the
  same bytes.

  ## The key is the content, so nothing has to be invalidated

  An entry is looked up by everything the rendering depends on — the text, the
  images that may be inlined, the author's verified links, the mention form,
  and the **locale** (a verified author link carries a translated title). Edit a
  post and its text is a different key, so the old entry is simply never asked
  for again and ages out. There is no invalidation path to forget to call.

  The key is a SHA-256 of those parts rather than `:erlang.phash2/1`
  deliberately: a phash2 collision is rare but its failure mode is serving one
  member's post body inside another member's card, silently. That is not a risk
  worth a few bytes.

  ## What the staleness costs

  An entry lives #{div(300_000, 1000)}s. The pipeline asks the database two
  questions about the world — does this `@handle` name a member, does this
  `#hashtag` name a topic worth linking — so within that window a handle
  registered a moment ago stays plain text in an already-rendered body. It
  heals on its own, and `Vutuv.Tags.LinkableCache` in front of the hashtag half
  already accepts the same trade at 60s.

  Same shape as `Vutuv.Tags.LinkableCache` and `Vutuv.SocialFeed.Cache`: one
  GenServer owns a `read_concurrency` table, readers hit ETS directly and never
  call the process, and **a miss is simply the real render** — an absent table
  (this process is off in the test env, or boot has not finished) answers
  "missing" for everything, so behaviour is unchanged and only cheaper.

  `name:` and `table:` are injectable so a test can run an isolated instance;
  the app-wide one is off under `config :vutuv, :markdown_cache, false`.
  """

  use GenServer

  @table __MODULE__
  @ttl :timer.minutes(5)
  @sweep_interval :timer.minutes(1)

  # A ceiling on what the table may hold, so a burst of distinct bodies (a
  # crawler walking every permalink, an import) cannot grow it without bound.
  # Bodies run to a few kB, so this is tens of megabytes at worst. Past it the
  # sweeper empties the table rather than evicting cleverly: the entries are a
  # memo, losing them costs one re-render each, and a least-recently-used order
  # would cost a write on every read to maintain.
  @max_entries 20_000

  @doc """
  The remembered HTML for `parts`, or `:miss`.

  `parts` is any term identifying the render completely — see the moduledoc on
  what has to be in it. A caller-side ETS read; an absent table is a miss.
  """
  def fetch(parts, table \\ @table) do
    key = key(parts)

    case :ets.lookup(table, key) do
      [{^key, html, expires_at}] ->
        if expires_at > System.monotonic_time(:millisecond), do: {:ok, html}, else: :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Remembers `html` as the rendering of `parts`, and returns it unchanged so a
  caller can wrap the real render in this without a `let`.
  """
  def put(parts, html, table \\ @table) do
    expires_at = System.monotonic_time(:millisecond) + @ttl
    :ets.insert(table, {key(parts), html, expires_at})
    html
  rescue
    ArgumentError -> html
  end

  @doc """
  The remembered HTML for `parts`, or what `fun` renders — which is then
  remembered. The one call shape the renderers use.
  """
  def render(parts, fun, table \\ @table) when is_function(fun, 0) do
    case fetch(parts, table) do
      {:ok, html} -> html
      :miss -> put(parts, fun.(), table)
    end
  end

  @doc "Ages every entry out on the spot (tests)."
  def expire_all(table \\ @table) do
    past = System.monotonic_time(:millisecond) - 1

    table
    |> :ets.tab2list()
    |> Enum.map(fn {key, html, _expires_at} -> {key, html, past} end)
    |> then(&:ets.insert(table, &1))

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "How long an entry is served for, in milliseconds."
  def ttl, do: @ttl

  @doc "How many entries the table may hold before it is emptied."
  def max_entries, do: @max_entries

  # SHA-256 rather than a cheap hash: see the moduledoc. `term_to_binary` gives
  # a canonical encoding of the whole tuple, so two renders differ in the key
  # whenever they differ in any part.
  defp key(parts), do: :crypto.hash(:sha256, :erlang.term_to_binary(parts))

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
    if :ets.info(table, :size) > @max_entries do
      :ets.delete_all_objects(table)
    else
      now = System.monotonic_time(:millisecond)
      # Expired rows only; `:"$3"` is the expiry stamp.
      :ets.select_delete(table, [{{:_, :_, :"$3"}, [{:"=<", :"$3", now}], [true]}])
    end

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
