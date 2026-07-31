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
  alias Vutuv.ScreenshotBlocklist.Entry

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

  @doc "Removes an entry, so that site can be captured again."
  def delete_entry(%Entry{} = entry), do: entry |> Repo.delete() |> announce()

  defp announce({:ok, _entry} = result) do
    Phoenix.PubSub.broadcast(Vutuv.PubSub, Cache.topic(), :blocklist_changed)
    result
  end

  defp announce(result), do: result

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
