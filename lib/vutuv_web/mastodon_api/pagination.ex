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

  import Ecto.Query
  import Plug.Conn

  alias Vutuv.MastodonApi
  alias Vutuv.UUIDv7

  @default_limit 20
  @max_limit 40

  defstruct limit: @default_limit, max_id: nil, since_id: nil, min_id: nil

  @doc "Reads the four parameters, clamping `limit` to Mastodon's 1..40."
  def params(params, opts \\ []) do
    %__MODULE__{
      limit: parse_limit(params, Keyword.get(opts, :default_limit, @default_limit)),
      max_id: UUIDv7.cast_or_nil(params["max_id"]),
      since_id: UUIDv7.cast_or_nil(params["since_id"]),
      min_id: UUIDv7.cast_or_nil(params["min_id"])
    }
  end

  @doc """
  Narrows a query to the requested window and orders it.

  `min_id` flips the order to oldest-first so the **oldest** unseen rows are
  taken; `reverse/2` puts the page back into the newest-first order every
  Mastodon response is in.
  """
  def scope(query, %__MODULE__{} = page, field \\ :id) do
    query
    |> maybe_where(page.max_id, fn q, id -> where(q, [r], field(r, ^field) < ^id) end)
    |> maybe_where(page.since_id, fn q, id -> where(q, [r], field(r, ^field) > ^id) end)
    |> maybe_where(page.min_id, fn q, id -> where(q, [r], field(r, ^field) > ^id) end)
    |> order_by([r], [{^direction(page), field(r, ^field)}])
    |> limit(^page.limit)
  end

  @doc "Restores newest-first after a `min_id` page was fetched oldest-first."
  def reverse(rows, %__MODULE__{min_id: nil}), do: rows
  def reverse(rows, %__MODULE__{}), do: Enum.reverse(rows)

  @doc """
  How much to ask an underlying reader for, so the window below still has a
  full page left after the boundary ties are dropped.

  A merged feed's own cursor is second-precision and cannot separate entries
  written in the same second, so it can only narrow the fetch to the boundary
  second; the id comparison in `window/3` does the actual cutting. The headroom
  is how many entries may tie there before a page comes back short — which ends
  a client's walk one round early, and never repeats an entry.
  """
  def fetch_size(%__MODULE__{max_id: nil, since_id: nil, min_id: nil} = page), do: page.limit
  def fetch_size(%__MODULE__{} = page), do: page.limit + 20

  @doc """
  Cuts an already-fetched, newest-first list to the requested window.

  For readers that cannot take a keyset themselves — the merged feeds and the
  assembled account lists — where `scope/3` is not available. `id_fun` names the
  id a client would hand back, which is the one the response carries.
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
  """
  def link_header(conn, ids, %__MODULE__{} = page) do
    case Enum.reject(ids, &is_nil/1) do
      [] ->
        conn

      present ->
        newest = Enum.max(present)
        oldest = Enum.min(present)
        next = if length(present) >= page.limit, do: link(conn, page, max_id: oldest)

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

  defp link(conn, %__MODULE__{limit: limit}, boundary) do
    query =
      boundary
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Map.new()
      |> Map.put("limit", to_string(limit))

    MastodonApi.api_url(conn.request_path) <> "?" <> URI.encode_query(query)
  end

  defp direction(%__MODULE__{min_id: nil}), do: :desc
  defp direction(%__MODULE__{}), do: :asc

  defp maybe_where(query, nil, _fun), do: query
  defp maybe_where(query, id, fun), do: fun.(query, id)

  defp parse_limit(%{"limit" => value}, default) do
    case Integer.parse(to_string(value)) do
      {limit, _rest} -> limit |> max(1) |> min(@max_limit)
      :error -> default
    end
  end

  defp parse_limit(_params, default), do: default
end
