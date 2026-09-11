defmodule Vutuv.Tags.Trending do
  @moduledoc """
  What is suddenly busy on the servers this installation reads from, and what
  happens when somebody follows one of those tags (issue #2129).

  When a conference runs or something happens, a topic goes from nothing to
  hundreds of posts within the hour, and a member here hears of it only if they
  already follow that tag. Every Mastodon server publishes its trending tags
  with a seven-day history, without a login and for one request each, so the
  feed's tag card can offer what is spiking elsewhere.

  ## Suddenly busy, not busy

  The seven-day history is the whole point. `#xbox` stood at 130 uses on the day
  this was written, more than most tags ever see, against a median of 78 on the
  six days before — that is what `#xbox` does every day, and offering it would
  be offering a permanent fixture as news. `#warntag` stood at 5,994 uses across
  ten servers against a median of 25. So a tag is offered when today's total
  clears `min_uses`, is at least `spike_factor` times the median of the six days
  before it, and at least `min_servers` servers list it at all.

  Every figure is the **sum over the servers listing the tag**, so "how much
  louder than usual is this" is asked of the whole neighbourhood rather than of
  whichever server happens to be biggest.

  ## The loudest tag is often a machine

  `#mow4` trended on seven of the nine servers that answered, which is to say
  the spread test does **not** catch it: a bot farm that federates widely trends
  everywhere. What catches it is the tag's own timeline, and both facts on it
  are the remote server's own rather than anything we work out. Measured over
  ten trending tags on 10 September 2026, forty statuses each:

    * **distinct author domains** — 1 for `#mow4` on troet.cafe (40 of 40 from
      `social.prepedia.org`), 2 on mastodon.social, and 13 to 26 for every other
      tag. `min_author_hosts` sits at 4.
    * **bot accounts**, as the server flags them — 39 or 40 of 40 for `#mow4`,
      and at most 10 of 40 (25 %) for anything else. `max_bot_percent` sits
      at 50.

  Both margins are wide because the phenomenon is not subtle. A tag nobody can
  be sampled for at all is **not** offered: failing closed costs one good tag on
  a bad minute and is the only safe direction.

  **The census counts strangers only** (issue #2196). Our own posts federate out
  with their hashtags, so the servers asked here hand them straight back, and
  counting them made this installation one more author server on the very gate
  meant to catch a single source — `Vutuv.Tags.ExternalTagClient.author_entry/2`
  carries the measurement and why they are dropped there rather than subtracted
  here. Both figures above are therefore about the world outside, as is the
  sample they are taken from. The tag's **volume** is not, and cannot be:
  `/api/v1/trends/tags` carries no author, so a remote server's `uses` counts
  our echo and there is nothing in the answer to subtract. Such a tag still
  becomes a candidate and still spends one of the `vet_limit` census slots —
  what drops it is running out of *sample*, the same failing-closed direction as
  everything else here.

  ## A spike shortens the pull at once

  A tag this installation already pulls has a measured pace
  (`Vutuv.Tags.ExternalPosts`), and that pace only learns about a news event
  after the event has already filled a fetch. So every spiking candidate that
  names a tag followed here is put back to the cadence floor on the spot —
  before the vetting, because hurrying a tag somebody already chose is not the
  same question as offering one to somebody who did not.

  ## One pass, every server

  `refresh/0` runs when **any** server is due and then asks **all** of them.
  That is deliberate: the spread is a count of servers, and a pass that asked
  three of ten would recompute it from three answers and empty the offer. The
  clock is uniform for the same reason — see `Vutuv.Tags.TrendCheck` — and it is
  stamped on every outcome, so a server that can never be asked leaves the due
  set instead of making the pass run on every tick of the two-minute loop.

  The offer is replaced wholesale by each pass, which is why nothing here has to
  reconcile a name two passes disagree about.
  """

  import Ecto.Query

  require Logger

  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.SlugHelpers
  alias Vutuv.Tags
  alias Vutuv.Tags.ExternalPosts
  alias Vutuv.Tags.ExternalTagClient
  alias Vutuv.Tags.SourceServer
  alias Vutuv.Tags.SourceServers
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.TrendCheck
  alias Vutuv.Tags.TrendingTag

  @flag :fetch_trending_tags

  @settings [
    offer: 5,
    min_uses: 25,
    spike_factor: 5,
    min_servers: 2,
    min_author_hosts: 4,
    max_bot_percent: 50,
    min_sample: 10,
    vet_limit: 8,
    interval_minutes: 30
  ]

  @empty_tally %{asked: 0, listed: 0, empty: 0, skipped: 0, failed: 0, offered: 0, hurried: 0}

  @doc """
  Whether this installation asks other servers what is trending on them.

  Two switches, and the pull's own comes first: a server this installation may
  not fetch from is not one to take a recommendation from either.
  """
  def enabled? do
    ExternalPosts.enabled?() and Application.get_env(:vutuv, @flag, true) == true
  end

  @doc """
  Whether this installation asks anybody at all what is trending on them.

  The row draws an empty state rather than vanishing (issue #2165), and "nothing
  stood out today" is only honest where somebody was asked. An installation with
  the flag off, or an intranet one whose `TAG_SOURCE_SERVERS` is the empty list
  that `Vutuv.Tags.SourceServers` documents as a real setting, reads no other
  servers at all — it gets no row, not a nightly report about servers it never
  touches.

  Every feed page load asks this, so it is deliberately `configured?/0` and not
  `offered/0`: the second answers *whom* and pays a blocklist query for it
  (measured at 417 µs and one round trip), while the question here is whether
  there is anybody to ask, which is configuration.
  """
  def asking?, do: enabled?() and SourceServers.configured?()

  @doc "The thresholds and the pace — see the moduledoc for where each number comes from."
  def settings, do: Application.get_env(:vutuv, :tag_trending, @settings)

  @doc "How long between two passes."
  def interval_seconds, do: settings()[:interval_minutes] * 60

  # An offer nobody has refreshed for four passes is not "right now" any more.
  # Derived rather than configured: it is a statement about the pace above, and
  # a second knob would only let an operator make the two disagree.
  defp max_age_seconds(settings), do: settings[:interval_minutes] * 60 * 4

  @doc """
  The servers a pass is waiting on: those the operator offers with no row yet,
  or whose row has come due.

  A pass runs when this is not empty and then asks **every** offered server, so
  this decides *when*, never *whom*.
  """
  def due_servers, do: if(enabled?(), do: due_servers(SourceServers.offered()), else: [])

  defp due_servers(offered) do
    now = DateTime.utc_now(:second)

    checked =
      from(c in TrendCheck, where: c.host in ^offered and c.next_check_at > ^now, select: c.host)
      |> Repo.all()
      |> MapSet.new()

    Enum.reject(offered, &MapSet.member?(checked, &1))
  end

  @doc """
  One pass: ask every offered server what is trending, hurry the followed tags
  that are spiking, vet the rest and replace the offer.

  `:disabled` when the installation asks nobody anything; a tally otherwise.
  Sequential, like the pull beside it — ten small requests in a row, and the
  next pass is half an hour away.
  """
  def refresh do
    if enabled?() do
      # Read once and handed down: `offered/0` normalizes the operator's list
      # and asks the blocklist, so calling it again per step is two more queries
      # per pass for an answer that cannot change inside one.
      offered = SourceServers.offered()

      if due_servers(offered) == [], do: @empty_tally, else: run(offered, settings())
    else
      :disabled
    end
  end

  defp run(offered, settings) do
    results = Enum.map(offered, &ask/1)
    now = DateTime.utc_now(:second)
    Enum.each(results, &stamp(&1, now, settings))

    answers = for {host, :listed, entries} <- results, do: {host, entries}
    candidates = answers |> aggregate() |> judged(settings)
    hurried = hurry(candidates)
    offered_count = candidates |> vetted(settings) |> replace_offer(now)

    tally(results, offered_count, hurried)
  end

  # Everything one server's answer can be, with the outcome the clock records.
  # The work is guarded rather than left to raise: a pass that stopped here
  # would leave every server behind this one unstamped, which is the deadlock
  # `Vutuv.Tags.TrendCheck` describes. The guard is the pull's own
  # (`ExternalPosts.guard/2`) — same contract, same reason, one owner.
  defp ask(host) do
    case ExternalPosts.guard("trends #{host}", fn -> ExternalTagClient.trending(host) end) do
      {:ok, {:ok, []}} -> {host, :empty, []}
      {:ok, {:ok, entries}} -> {host, :listed, entries}
      {:ok, {:error, reason}} -> {host, outcome_of(reason), []}
      :crashed -> {host, :failed, []}
    end
  end

  defp outcome_of(reason), do: if(ExternalTagClient.skip?(reason), do: :skipped, else: :failed)

  # One statement, the recipe the pull's own clock uses: two overlapping runs —
  # the blue/green window — cannot collide on the host's unique index, and
  # nothing has to be read back first. Its own failure is caught rather than
  # raised, for the same reason the ask's is: one server's trouble must not cost
  # the ones behind it their clock.
  defp stamp({host, outcome, _entries}, now, settings) do
    params = %{
      host: host,
      checked_at: now,
      next_check_at: DateTime.add(now, settings[:interval_minutes] * 60),
      last_outcome: to_string(outcome)
    }

    ExternalPosts.guard("clock for #{host}", fn ->
      %TrendCheck{}
      |> TrendCheck.changeset(params)
      |> Repo.insert(
        on_conflict: {:replace, [:checked_at, :next_check_at, :last_outcome, :updated_at]},
        conflict_target: [:host]
      )
    end)
  end

  # --- What the servers said ------------------------------------------------

  # One entry per name, with every server's answer folded into it: the week's
  # totals added day by day, and each server's own count of today kept so the
  # busiest one can be asked for the vetting sample and named as a source.
  defp aggregate(answers) do
    answers
    |> Enum.reduce(%{}, fn {host, entries}, acc ->
      Enum.reduce(entries, acc, &fold(&2, host, &1))
    end)
    |> Map.values()
  end

  defp fold(acc, host, %{name: name, history: history}) do
    key = String.downcase(name)
    today = List.first(history) || 0

    Map.update(
      acc,
      key,
      %{name: name, top: today, hosts: %{host => today}, history: history},
      fn seen ->
        %{
          # The spelling of the server that sees the most of it. A tag's casing
          # is its first writer's here (`Vutuv.Tags.Tag`), and out there it is
          # whoever the crowd is — so the crowd decides.
          name: if(today > seen.top, do: name, else: seen.name),
          top: max(today, seen.top),
          hosts: Map.put(seen.hosts, host, today),
          history: Enum.zip_with(seen.history, history, &+/2)
        }
      end
    )
  end

  # The judgement, and the order the offer is built in: loudest first, which is
  # also what the mock shows. The ratio is the gate rather than the ranking —
  # a tag going from 0 to 30 has an unbounded ratio and is not the news.
  defp judged(entries, settings) do
    entries
    |> Enum.map(&summarise/1)
    |> Enum.filter(&spiking?(&1, settings))
    |> Enum.sort_by(&{-&1.uses, &1.name})
  end

  defp summarise(entry) do
    [today | previous] = entry.history

    %{
      name: entry.name,
      uses: today,
      baseline: median(previous),
      history: entry.history,
      servers: map_size(entry.hosts),
      # Most uses first: what `follow/2` names as sources, and the first of them
      # is the server with the most material to vet the tag on.
      hosts:
        entry.hosts
        |> Enum.sort_by(fn {host, uses} -> {-uses, host} end)
        |> Enum.map(&elem(&1, 0))
    }
  end

  defp median([]), do: 0

  defp median(values) do
    sorted = Enum.sort(values)
    middle = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1 do
      Enum.at(sorted, middle)
    else
      div(Enum.at(sorted, middle - 1) + Enum.at(sorted, middle), 2)
    end
  end

  defp spiking?(row, settings) do
    row.uses >= settings[:min_uses] and row.servers >= settings[:min_servers] and
      row.uses >= max(row.baseline, 1) * settings[:spike_factor] and mintable?(row.name)
  end

  # A name that could not become a tag here must never be offered: the row's one
  # control mints the tag, and a `#2026` or a `#日本語` would file a topic at
  # `/tags/2026` or at a random hex string. `Vutuv.Tags.mintable_hashtag?/1` is
  # the same gate a `#hashtag` in a post body passes, so the row cannot mint
  # anything the composer would not. The length is the column's, and it is the
  # only bound the trending list itself does not already impose.
  defp mintable?(name) do
    Tags.mintable_hashtag?(name) and byte_size(name) <= TrendingTag.max_name()
  end

  # --- The bot defence ------------------------------------------------------

  # Walks the candidates loudest first, asking each one's busiest server who is
  # posting it, and stops when the budget of requests is spent. Everything that
  # survives is stored, not only what one reader will see: the reader takes what
  # they do not already follow out, and a thinner list would leave them nothing.
  defp vetted(candidates, settings) do
    candidates
    |> Enum.take(settings[:vet_limit])
    |> Enum.map(&vet(&1, settings))
    |> Enum.reject(&is_nil/1)
  end

  defp vet(%{hosts: [host | _rest]} = row, settings) do
    case ExternalPosts.guard("census #{host}", fn -> ExternalTagClient.authors(host, row.name) end) do
      {:ok, {:ok, entries}} -> verdict(row, entries, settings)
      _refused -> nil
    end
  end

  defp verdict(row, entries, settings) do
    sampled = length(entries)
    hosts = entries |> Enum.map(& &1.host) |> Enum.uniq() |> length()
    bots = Enum.count(entries, & &1.bot?)

    passes? =
      sampled >= settings[:min_sample] and hosts >= settings[:min_author_hosts] and
        bots * 100 <= sampled * settings[:max_bot_percent]

    if passes?,
      do: Map.merge(row, %{author_hosts: hosts, bot_posts: bots, sampled: sampled}),
      else: nil
  end

  # --- The offer ------------------------------------------------------------

  # One transaction, so the two slots of a blue/green deploy cannot leave a
  # reader looking at half a pass.
  defp replace_offer(rows, now) do
    {:ok, stored} =
      Repo.transaction(fn ->
        Repo.delete_all(TrendingTag)
        Enum.count(rows, &store_offer(&1, now))
      end)

    stored
  end

  # A refused row is logged and dropped rather than raised: the values are a
  # stranger's and the pass has nine other tags to store.
  defp store_offer(row, now) do
    case %TrendingTag{}
         |> TrendingTag.changeset(Map.put(row, :checked_at, now))
         |> Repo.insert() do
      {:ok, _row} ->
        true

      {:error, changeset} ->
        Logger.warning("Trending tag #{row.name} not stored: #{inspect(changeset.errors)}")
        false
    end
  end

  @doc """
  What the card offers, loudest first.

    * `:except` — names the reader already follows, matched the way a tag is
      matched here (case- and separator-insensitively through the slug), so a
      member following `#Warntag` is not offered `warntag`.
    * `:limit` — how many to draw; the configured `offer` by default.

  Empty when the feature is off, and empty when the last pass is older than four
  intervals — "right now" stops being true at some point, and a sweeper that
  died must not leave three-day-old news on the card.
  """
  def offers(opts \\ []) do
    if enabled?() do
      settings = settings()
      cutoff = DateTime.add(DateTime.utc_now(:second), -max_age_seconds(settings))
      except = opts |> Keyword.get(:except, []) |> MapSet.new(&SlugHelpers.tagify/1)

      from(t in TrendingTag, where: t.checked_at > ^cutoff, order_by: [desc: t.uses, asc: t.name])
      |> Repo.all()
      |> Enum.reject(&MapSet.member?(except, SlugHelpers.tagify(&1.name)))
      |> Enum.take(Keyword.get(opts, :limit, settings[:offer]))
    else
      []
    end
  end

  @doc """
  Follows an offered tag as `user`, minting it here if nothing answers to it yet
  and naming the servers it is busy on as its sources.

  **The offer is the permission.** A name that is not on it comes back
  `{:error, :not_offered}` rather than being minted, so a pushed event cannot
  put an arbitrary word into a namespace every member shares — the same reason
  the card's typed follow field refuses a name no tag answers to.

  Minting is right here where it is wrong there: this name is demonstrably a
  topic several servers are busy with, and following it with no sources would
  subscribe the member to a tag nobody here has ever written.
  """
  def follow(%User{} = user, name) do
    with %TrendingTag{} = row <- Repo.get_by(TrendingTag, name: to_string(name)),
         tag_id when is_binary(tag_id) <- Tags.find_or_create_tag_id(row.name),
         {:ok, follow} <- Tags.follow_tag(user, tag_id) do
      Enum.each(sources(row), &Tags.add_tag_follow_source(follow, &1))
      {:ok, Repo.get(Tag, tag_id)}
    else
      nil -> {:error, :not_offered}
      {:error, reason} -> {:error, reason}
    end
  end

  # The servers this tag is busiest on, minus any we already know will not serve
  # their timeline to a logged-out reader. Nothing is probed here: these are the
  # operator's own configured servers and a pass has just had an answer out of
  # each, so a click costs no outbound request. The cap is
  # `Tags.add_tag_follow_source/2`'s, which is where it has to be.
  defp sources(%TrendingTag{hosts: hosts}) do
    known = SourceServers.infos(hosts)

    hosts
    |> Enum.reject(fn host ->
      case Map.get(known, host) do
        %SourceServer{} = info -> not SourceServer.pickable?(info)
        nil -> false
      end
    end)
    |> Enum.take(SourceServers.limit())
  end

  # --- Hurrying a followed tag ----------------------------------------------

  defp hurry(candidates) do
    candidates |> Enum.map(&SlugHelpers.tagify(&1.name)) |> ExternalPosts.hurry()
  end

  defp tally(results, offered, hurried) do
    Enum.reduce(results, %{@empty_tally | offered: offered, hurried: hurried}, fn
      {_host, outcome, _entries}, acc ->
        acc |> Map.update!(:asked, &(&1 + 1)) |> Map.update!(outcome, &(&1 + 1))
    end)
  end
end
