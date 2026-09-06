defmodule Vutuv.ScreenshotBlocklist do
  @moduledoc """
  The pages this installation never takes a link-preview screenshot of.

  Some sites answer a headless capture with a cookie-consent banner, a login
  wall or a bot check, so the shot is never the page a reader expected — it is
  a picture of a dialog. Listing them here skips the Chromium run instead of
  spending one on something that cannot work, for **both** capture paths: the
  profile links (`Vutuv.PageScreenshot`) and the single-link post queue
  (`Vutuv.Posts.Screenshots`).

  ## Per-installation data, edited by admins

  Which sites need this is a property of the installation, not of the code, and
  it changes the day a site adds a consent layer — so the list lives in the
  `screenshot_blocklist_entries` table with an editor at
  **`/admin/screenshots?tab=blocklist`**, the way the legal pages do
  (`Vutuv.Legal`). `:screenshot_blocklist` in `config/config.exs` (and
  `SCREENSHOT_BLOCKLIST` in the environment) is only the **seed** a fresh
  installation starts with; the migration copies it into the table once, and
  from then on the admin page owns the list.

  Reads go through `Vutuv.ScreenshotBlocklist.Cache` (`:persistent_term`), so a
  check costs no query on the request path.

  ## Entry grammar

  Each entry is a domain or a URL:

      heise.de                      # the site: apex + every subdomain, any path
      *.heise.de                    # the same rule spelled out
      example.com/news              # that path and everything below it
      example.com/*/private         # `*` stands for exactly one segment
      example.com/news/*            # a trailing `*` is the rest of the path
      https://example.com/story-1   # one page (the scheme is ignored)

  Matching rules, and why:

    * **Hosts match at the label boundary**, so `heise.de` covers `www.heise.de`
      and `m.heise.de` but never `notheise.de`. One entry covers a site's
      mirrors, which is what an admin means by naming a domain.
    * A leading `*.` or `www.` on an entry is dropped: both spell "this site".
      A blocklist entry that matched *fewer* URLs than the admin intended is
      the worse mistake, so the wildcard form includes the apex.
    * **Paths match whole segments**, so `example.com/news` covers `/news/2026`
      but not `/newsroom` — the prefix-match trap.
    * Scheme, port, query and fragment are ignored: `?utm_source=…` and a
      pasted `http://` are the same page, and neither may defeat an entry.

  A value with no host at all (a `mailto:` link, junk) is not blocked — there
  is nothing to capture there anyway, and the capture path refuses it on its
  own. An entry that names no host is refused by the changeset rather than
  stored as a line that silently matches nothing (or everything).
  """

  import Ecto.Query

  alias Vutuv.Repo
  alias Vutuv.ScreenshotBlocklist.Cache
  alias Vutuv.ScreenshotBlocklist.Check
  alias Vutuv.ScreenshotBlocklist.Entry

  require Logger

  # How long a `usable` verdict stands before the host is looked at again. A
  # site adds a consent layer or an ad wall the day its business changes, so a
  # verdict is a measurement with an age, not a permanent property — but at
  # roughly five captures per host, re-asking every quarter costs a rounding
  # error and keeps the list honest.
  @recheck_after_days 90
  # How long an `unknown` stands — the verdict that says the check itself could
  # not answer. Short, because whatever was wrong may be gone tomorrow; not
  # zero, because a host that is asked again on every capture pays the ballot
  # every time.
  @unknown_retry_days 1

  @doc """
  True when `url` matches an entry of the blocklist.

  Cheap and query-free (string work on the parsed URL against the cached
  patterns), so it is safe on the request path — `qualifying_url/1` calls it
  while a post is being saved, and the profile Links card calls it per
  rendered link.
  """
  def blocked?(url) when is_binary(url) do
    case target(url) do
      nil -> false
      {host, segments} -> Enum.any?(patterns(), &matches?(&1, host, segments))
    end
  end

  def blocked?(_url), do: false

  ## The list

  @doc "Every entry, alphabetically — what the admin page lists."
  def list_entries do
    Repo.all(from(e in Entry, order_by: [asc: e.pattern]))
  end

  @doc "How many entries the list has (the admin tab label)."
  def count_entries, do: Repo.aggregate(Entry, :count)

  @doc "Loads one entry by id, raising when it is gone."
  def get_entry!(id), do: Repo.get!(Entry, id)

  @doc "Loads one entry by id, or `nil` — what a route serving its evidence needs."
  def get_entry(id), do: Repo.get(Entry, id)

  @doc "A changeset for the admin page's add form."
  def change_entry(%Entry{} = entry \\ %Entry{}, attrs \\ %{}) do
    Entry.changeset(entry, attrs)
  end

  @doc """
  Adds an entry. The new line takes effect at once (the cache reloads on every
  node), so the next capture of that page is skipped; screenshots taken before
  it are cleaned up separately (`Vutuv.PageScreenshot.purge_blocklisted/0`).
  """
  def create_entry(attrs) do
    %Entry{}
    |> Entry.changeset(attrs)
    |> Repo.insert()
    |> announce()
  end

  @doc """
  Removes an entry, so that site can be captured again.

  Deleting an **automatic** entry is an admin overruling the model, so it also
  records a `usable` verdict for that host, marked as theirs: without it the
  next capture of the site would be judged again, reach the same conclusion,
  and put the line straight back — the admin's decision has to outlive the
  click, and a decision by a person does not expire the way a measurement
  does.
  """
  def delete_entry(%Entry{} = entry) do
    result = entry |> Repo.delete() |> announce()

    with {:ok, _entry} <- result, "ai" <- entry.source do
      if entry.evidence_file, do: File.rm(evidence_path(entry.evidence_file))
      overrule(entry)
    end

    result
  end

  defp overrule(%Entry{pattern: pattern}) do
    case parse(pattern) do
      {host, _segments} ->
        record_check(%{
          host: host,
          verdict: "usable",
          source: "admin",
          obstruction: "none",
          coverage_percent: 0,
          reason: "An admin removed the automatic blocklist entry for this site."
        })

      nil ->
        :ok
    end
  end

  defp announce({:ok, _entry} = result) do
    Phoenix.PubSub.broadcast(Vutuv.PubSub, Cache.topic(), :blocklist_changed)
    result
  end

  defp announce(result), do: result

  ## Page checks — the whitelist side

  @doc "How long a `usable` verdict stands before its host is looked at again."
  def recheck_after_days, do: @recheck_after_days

  @doc """
  The host an entry or a URL names, normalised the way patterns are (no
  scheme, no `www.`, no port), or `nil` when there is no host to name.
  """
  def host_of(url) when is_binary(url) do
    case parse(url) do
      {host, _segments} -> host
      nil -> nil
    end
  end

  def host_of(_url), do: nil

  @doc "The stored verdict for a host, or `nil` when it was never judged."
  def get_check(host) when is_binary(host), do: Repo.get_by(Check, host: host)
  def get_check(_host), do: nil

  @doc """
  True when this host was judged recently enough not to ask again — the
  whitelist question, asked before a fresh capture is judged.

  Every verdict answers it, not just `usable`, and each has its own age:

    * a person's decision (`source: "admin"`) never expires. A measurement can
      go stale; somebody's judgement about their own installation does not, and
      an admin who removed an entry must not have the model put it back.
    * `usable` stands for `recheck_after_days/0` — a site adds a consent layer
      the day its business changes.
    * `unknown` stands for a day. It means the check itself could not answer
      (an undecodable picture, an outvoted suspicion), and without an age at
      all such a host would pay the full ballot on **every** capture: the
      busiest host here is captured over a hundred times a day.

  A `blocked` verdict answers with its own re-check age too, but rarely gets
  asked: the blocklist entry it wrote stops the capture before Chromium runs.
  """
  def judged_recently?(host) when is_binary(host), do: fresh?(get_check(host))
  def judged_recently?(_host), do: false

  @doc """
  Whether a stored verdict is young enough to stand. Public because the
  backfill asks it of rows it has already loaded.
  """
  def fresh?(nil), do: false
  def fresh?(%Check{source: "admin"}), do: true

  def fresh?(%Check{verdict: verdict, checked_at: checked_at}) do
    age = DateTime.diff(DateTime.utc_now(), checked_at, :day)

    case verdict do
      "unknown" -> age < @unknown_retry_days
      _usable_or_blocked -> age < @recheck_after_days
    end
  end

  @doc """
  Writes (or replaces) the verdict for one host. `checked_at` defaults to now,
  which is what every caller but a test means.
  """
  def record_check(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:checked_at, DateTime.utc_now(:second))

    %Check{}
    |> Check.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :host, :inserted_at]},
      conflict_target: :host
    )
  end

  @doc """
  Records what the page check saw: `verdict` is `"usable"`, `"blocked"` or
  `"unknown"`, and the model's own fields come from the `verdict` map it
  returned. One writer, so a new field on the row is one edit rather than one
  per caller.
  """
  def record_verdict(host, url, verdict, answer) when is_binary(host) do
    record_check(%{
      host: host,
      verdict: verdict,
      source: "ai",
      obstruction: Map.get(answer, :obstruction),
      coverage_percent: Map.get(answer, :coverage_percent),
      reason: Map.get(answer, :reason),
      checked_url: url,
      model: Vutuv.Ollama.vision_model()
    })
  end

  @doc """
  Records a `blocked` verdict **and** the blocklist entry that follows from
  it: from now on this installation never captures that site, and the admin
  page shows the model's reason beside the line.

  `evidence_path` is the judged capture. It is copied into the private
  evidence tree **after** the entry exists, under that entry's id, so an admin
  reviewing the line sees the picture the verdict was formed on — and a second
  capture of the same host, in flight while the first one won, leaves no
  orphaned file behind: the unique index on `pattern` is the referee, not a
  cache lookup. Nothing here raises; a failed copy costs the picture, not the
  decision.

  Returns `{:ok, entry}` or `{:ok, :already_blocked}`.
  """
  def block_host(host, url, verdict, evidence_path \\ nil) when is_binary(host) do
    record_verdict(host, url, "blocked", verdict)

    %Entry{}
    |> Entry.auto_changeset(%{pattern: host, note: auto_note(verdict), source: "ai"})
    |> Repo.insert()
    |> announce()
    |> attach_evidence(evidence_path)
  end

  defp attach_evidence({:ok, %Entry{} = entry}, evidence_path) do
    case store_evidence(entry.id, evidence_path) do
      nil -> {:ok, entry}
      filename -> entry |> Ecto.Changeset.change(evidence_file: filename) |> Repo.update()
    end
  end

  # The site was already on the list — an admin wrote it while this capture
  # was in flight, or a second capture of the same host won the race. The
  # verdict is recorded either way; there is nothing else to do.
  defp attach_evidence({:error, _changeset}, _evidence_path), do: {:ok, :already_blocked}

  # The line an admin reads in the list. The model's own sentence is the
  # honest record of what it saw, and the obstruction word in front of it
  # groups the entries at a glance.
  defp auto_note(verdict) do
    obstruction = Map.get(verdict, :obstruction) || "other"
    reason = Map.get(verdict, :reason) || "no reason given"

    String.slice("#{obstruction}: #{reason}", 0, 255)
  end

  @doc """
  Deletes the stored captures of every page that is on the list today, across
  all three queues, and returns the counts as
  `%{links: n, posts: n, organizations: n}`.

  Adding an entry only stops **new** captures — a link is re-captured when its
  URL changes, and a page nobody re-posts keeps the consent-dialog picture it
  got before the entry existed. Three callers need exactly this: the admin
  button, the release task, and the sweeper after the page check has just
  blocked a site. It lives here because forgetting one of the three is
  invisible (the admin button did forget the organization queue until this
  became one function).
  """
  def purge_captures do
    %{
      links: Vutuv.PageScreenshot.purge_blocklisted(),
      posts: Vutuv.Posts.Screenshots.purge_blocklisted(),
      organizations: Vutuv.Organizations.Screenshots.purge_blocklisted()
    }
  end

  @doc "The absolute path of a stored evidence picture."
  def evidence_path(filename) when is_binary(filename),
    do: Path.join(Vutuv.Uploads.disk_dir("screenshot_evidence"), filename)

  defp store_evidence(_id, nil), do: nil

  defp store_evidence(id, source_path) do
    extension = Path.extname(source_path)
    filename = "#{id}#{extension}"
    target = evidence_path(filename)

    with :ok <- File.mkdir_p(Path.dirname(target)),
         {:ok, _bytes} <- File.copy(source_path, target) do
      filename
    else
      error ->
        Logger.warning("screenshot evidence copy failed for #{id}: #{inspect(error)}")
        nil
    end
  end

  ## Patterns

  @doc """
  The parsed patterns: the cached list, or a direct read when the cache holds
  nothing (test env, or the moment before boot finishes).
  """
  def patterns do
    case Cache.read() do
      :not_loaded -> load_patterns()
      patterns -> patterns
    end
  end

  @doc "Reads and parses the stored entries — what the cache holds."
  def load_patterns do
    Entry
    |> select([e], e.pattern)
    |> Repo.all()
    |> Enum.map(&parse/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Parses one entry into a `{host_pattern, path_segments}` pair, or `nil` when
  it names no host. Public because the changeset validates with it: a line that
  cannot match is refused at the form, not silently kept.
  """
  def parse(entry) when is_binary(entry) do
    entry
    |> String.trim()
    |> String.downcase()
    |> strip_scheme()
    |> String.split("/", parts: 2)
    |> case do
      [host] -> pattern(host, "")
      [host, path] -> pattern(host, path)
    end
  end

  def parse(_entry), do: nil

  defp strip_scheme(entry) do
    case String.split(entry, "://", parts: 2) do
      [_scheme, rest] -> rest
      [rest] -> String.trim_leading(rest, "//")
    end
  end

  defp pattern(host, path) do
    host =
      host
      |> String.trim_leading("*.")
      |> String.trim_leading("www.")
      |> String.trim_trailing(".")
      # A `host:port` entry names the same site as the host alone.
      |> String.split(":", parts: 2)
      |> hd()

    case host do
      "" -> nil
      host -> {host, String.split(path, "/", trim: true)}
    end
  end

  ## Matching

  # The URL under test, as {downcased host, downcased path segments}. A value
  # stored without a scheme (legacy profile links are not guaranteed to have
  # one) is read as an http URL rather than as a bare path.
  defp target(url) do
    uri = URI.parse(url)
    uri = if is_nil(uri.scheme) and is_nil(uri.host), do: URI.parse("http://" <> url), else: uri

    case uri.host do
      host when is_binary(host) and host != "" ->
        {String.downcase(host), segments(uri.path)}

      _no_host ->
        nil
    end
  end

  defp segments(nil), do: []
  defp segments(path), do: path |> String.downcase() |> String.split("/", trim: true)

  defp matches?({host_pattern, path_pattern}, host, segments) do
    host_matches?(host_pattern, host) and path_matches?(path_pattern, segments)
  end

  defp host_matches?("*", _host), do: true

  defp host_matches?(pattern, host) do
    host == pattern or String.ends_with?(host, "." <> pattern)
  end

  # An exhausted pattern matches whatever is left: naming a page also names
  # what sits below it.
  defp path_matches?([], _segments), do: true
  defp path_matches?(["*"], _segments), do: true

  defp path_matches?([p | rest_p], [s | rest_s]),
    do: (p == "*" or p == s) and path_matches?(rest_p, rest_s)

  defp path_matches?(_pattern, []), do: false
end
