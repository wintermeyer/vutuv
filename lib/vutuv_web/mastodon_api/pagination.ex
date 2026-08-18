defmodule VutuvWeb.MastodonApi.Pagination do
  @moduledoc """
  Mastodon's `limit` / `max_id` / `since_id` / `min_id` walk, and the `Link`
  header clients follow.

  Every timeline in a Mastodon client is an endless list, and the client asks
  for the next page by naming the id it already has. Without this a client can
  only ever see the newest page and scrolling back loads nothing, which is what
  the adapter did before.

  **vutuv's ids do the work.** They are `Vutuv.UUIDv7`, whose first 48 bits are
  the creation time, so they sort by age exactly like the snowflake ids Mastodon
  hands out — an id comparison *is* a time comparison, and `max_id`/`since_id`
  need no extra column, no offset and no stored cursor. That also means the
  boundary of a **merged** feed (several sources, no shared id space) can be read
  straight out of the id via `UUIDv7.timestamp/1`.

  The three parameters mean what they mean in Mastodon, and the difference
  between the last two is not cosmetic:

    * `max_id` — strictly older than this id (the "load more" direction).
    * `since_id` — newer than this id, still returning the **newest** page when
      more arrived than fit.
    * `min_id` — newer than this id, returning the **oldest** of those instead,
      so a client can walk forward through a gap without skipping anything.
  """

  import Plug.Conn

  alias Vutuv.Keyset
  alias Vutuv.MastodonApi
  alias Vutuv.UUIDv7

  @default_limit 20
  @max_limit 40

  # Every word a rendered id can carry in front of its uuid, from all three
  # minting sites: the merged feed's entry ids (`Vutuv.Posts`,
  # `Vutuv.Fediverse`), the prefixes `Vutuv.MastodonApi.Presenter` puts on
  # anything from another network, and the derived notification ids. One list
  # rather than one per controller: they were two hand-kept copies, and a
  # prefix added to a feed source has no reason to know which of them to
  # visit. None of these words can be the first group of a uuid (they are not
  # eight hex digits), so stripping is unambiguous.
  @id_prefixes ~w(post repost tagpost boost remote remote_repost note author reply like)

  defstruct limit: @default_limit, max_id: nil, since_id: nil, min_id: nil

  @doc """
  The bare uuid under a rendered id — the part that carries the creation time,
  and so the ordering every boundary here is read from.

  `"boost-01a0…"`, `"remote-repost-01a0…"`, `"remote-note-01a0…"` and a plain
  uuid all reduce to the same shape. This is the `:strip` every list endpoint
  passes to `params/2`; see the note there for what a missed prefix costs.
  """
  def bare_id(value) when is_binary(value) do
    case String.split(value, "-", parts: 2) do
      [prefix, rest] when prefix in @id_prefixes -> bare_id(rest)
      _plain_uuid -> value
    end
  end

  def bare_id(value), do: value

  @doc """
  The boundary id under every prefix a feed source can stamp on it.

  The forward direction of `bare_id/1`, and the reason it lives beside it: the
  merged home feed interleaves sources that share no id space, so its cursor
  names the boundary entry under each spelling rather than betting on one. That
  list was kept a second time in the timeline controller and had drifted — it
  held only single-word prefixes, so it could never name `remote-repost-<uuid>`
  or `remote-note-<uuid>`, which is exactly what `Vutuv.Fediverse` mints, and the
  boundary entry came back on the next page. A surplus guess costs nothing (these
  ids are unique, so a name nothing carries simply never matches), a missing one
  costs a duplicate row.
  """
  def prefixed_ids(uuid) when is_binary(uuid),
    do: Enum.map(@id_prefixes, &(&1 <> "-" <> uuid))

  @doc """
  Reads the four parameters, clamping `limit` to Mastodon's 1..40.

  **`:strip` is not optional for a list whose ids are prefixed.** A client hands
  back the `id` it was given, and several lists here render one that is not a
  bare uuid — `remote-<uuid>` for anything from another network, `like-<uuid>`
  for a derived notification. `UUIDv7.cast_or_nil/1` answers `nil` for those, a
  nil boundary is *no* boundary, and no boundary is the newest page — so a
  client walking such a list is sent back to the top of it on every "load more",
  forever. Pass a 1-arity function that reduces the rendered id to the uuid
  underneath (the part that carries the timestamp, and so the ordering).
  """
  def params(params, opts \\ []) do
    strip = Keyword.get(opts, :strip, & &1)

    boundary = fn key ->
      case params[key] do
        value when is_binary(value) -> value |> strip.() |> UUIDv7.cast_or_nil()
        _absent -> nil
      end
    end

    %__MODULE__{
      limit: parse_limit(params, Keyword.get(opts, :default_limit, @default_limit)),
      max_id: boundary.("max_id"),
      since_id: boundary.("since_id"),
      min_id: boundary.("min_id")
    }
  end

  @doc """
  The page as the plain options every context reader here takes
  (`Vutuv.Keyset`), so the boundary reaches the query instead of being filtered
  out of rows the query already returned.
  """
  def opts(%__MODULE__{} = page) do
    [limit: page.limit, max_id: page.max_id, since_id: page.since_id, min_id: page.min_id]
  end

  @doc """
  Narrows a query to the requested window and orders it — `Vutuv.Keyset.scope/3`
  for a caller that already holds the parsed page.
  """
  def scope(query, %__MODULE__{} = page, field \\ :id),
    do: Keyset.scope(query, opts(page), field)

  @doc "Restores newest-first after a `min_id` page was fetched oldest-first."
  def reverse(rows, %__MODULE__{} = page), do: Keyset.restore(rows, opts(page))

  @doc """
  How many rows to ask the **merged home feed** for, so its window still has a
  full page left after the boundary ties are dropped.

  For that one reader and no other. `Vutuv.Posts.feed_page/2` pages by a
  `{timestamp, seen ids}` cursor of second precision, which cannot separate
  entries written in the same second, so it narrows the read to the boundary
  second and `window/3` cuts on the ids. The headroom is how many entries may
  tie there before a page comes back short — which ends a client's walk one
  round early, and never repeats an entry.

  Every other list here takes a `Vutuv.Keyset` window instead. Reaching for
  this where a keyset would do is what capped all of them at 40 rows: the
  headroom is a fixed number, so the read runs out the moment the boundary is
  older than it, and the list ends silently.
  """
  def fetch_size(%__MODULE__{max_id: nil, since_id: nil, min_id: nil} = page), do: page.limit
  def fetch_size(%__MODULE__{} = page), do: page.limit + 20

  @doc """
  Cuts an already-bounded, newest-first list to the requested window.

  Only for a **merged** list — several sources with no shared id space, which
  no single query can order. Each source is bounded by the same window first
  (so the read stays the size of a page however deep the walk has gone), and
  this picks the page out of what they returned together. `id_fun` names the id
  a client would hand back, which is the one the response carries.
  """
  def window(entries, %__MODULE__{} = page, id_fun) when is_function(id_fun, 1) do
    entries
    |> Enum.filter(&in_window?(id_fun.(&1), page))
    |> then(fn kept -> if page.min_id, do: Enum.take(kept, -page.limit), else: kept end)
    |> Enum.take(page.limit)
  end

  defp in_window?(nil, _page), do: false

  defp in_window?(id, %__MODULE__{} = page) do
    (is_nil(page.max_id) or id < page.max_id) and
      (is_nil(page.since_id) or id > page.since_id) and
      (is_nil(page.min_id) or id > page.min_id)
  end

  @doc """
  The `Link` header for a page, given the ids it contains.

  `next` is only offered when the page came back full: a short page is the end
  of the list, and offering a next link there makes a client spin on an empty
  fetch forever. `prev` is always offered, because a list can grow at the top
  between two requests.

  `:more?` overrides that length test for a list that **filters after it
  reads** — the notifications page drops the vutuv-only kinds Mastodon has no
  type for, so a full read can still answer a short page while plenty is left
  behind it. Judging by the answer's length there ends the walk early and
  silently, which is the same failure the length test exists to prevent, just
  from the other side.
  """
  def link_header(conn, ids, %__MODULE__{} = page, opts \\ []) do
    case Enum.reject(ids, &is_nil/1) do
      [] ->
        conn

      present ->
        newest = Enum.max(present)
        oldest = Enum.min(present)
        more? = Keyword.get(opts, :more?, length(present) >= page.limit)
        next = if more?, do: link(conn, page, max_id: oldest)

        links =
          Enum.reject([{next, "next"}, {link(conn, page, min_id: newest), "prev"}], fn
            {nil, _rel} -> true
            _pair -> false
          end)

        case links do
          [] ->
            conn

          links ->
            put_resp_header(
              conn,
              "link",
              Enum.map_join(links, ", ", &~s(<#{elem(&1, 0)}>; rel="#{elem(&1, 1)}"))
            )
        end
    end
  end

  # The next page is offered on the host this request arrived on, never on the
  # canonical one: an installation may not have the subdomain at all, and a
  # client that signed in on the main host would follow a `next` link to an
  # origin its bearer token does not survive. `client_url/2` is exactly this
  # decision; naming `api_url/1` here quietly undid it for every "load more".
  defp link(conn, %__MODULE__{limit: limit}, boundary) do
    query =
      boundary
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Map.new()
      |> Map.put("limit", to_string(limit))

    MastodonApi.client_url(conn.host, conn.request_path) <> "?" <> URI.encode_query(query)
  end

  defp parse_limit(%{"limit" => value}, default) do
    case Integer.parse(to_string(value)) do
      {limit, _rest} -> limit |> max(1) |> min(@max_limit)
      :error -> default
    end
  end

  defp parse_limit(_params, default), do: default
end
