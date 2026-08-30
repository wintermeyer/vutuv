defmodule Vutuv.Keyset do
  @moduledoc """
  One page of a list a client walks by naming the last id it saw — the paging
  the Mastodon-compatible API's readers take (`VutuvWeb.MastodonApi.Pagination`
  parses the request into these options and writes the `Link` header from the
  answer).

  vutuv's ids are `Vutuv.UUIDv7`, whose first 48 bits are the creation
  millisecond, so an id comparison **is** a time comparison: a list can be paged
  by its own ids, with no offset column, no stored cursor, and no page that
  shifts under the reader when something new arrives at the top. That is the
  same property `Vutuv.Pages`' offset paging has to work around.

  **The boundary belongs in the query, not in a filter over rows the query
  already returned.** A reader that fetches the newest N and then drops
  everything outside the window runs out of rows as soon as the boundary is
  older than the Nth, and answers an *empty page* — for that request and every
  request after it. Nothing errors and nothing is logged; a 200-post profile
  simply looks like an N-post one. Every Mastodon list here did exactly that
  (N was 40) until this module existed, so treat an in-memory window over an
  unbounded read as the bug it is, not as an optimisation to get to later.
  A merged list — several sources with no shared id space — still cuts in
  memory, but only *after* each source has been bounded by the same window, so
  the deepest page reads as few rows as the first.

  The three boundaries mean what they mean in Mastodon, and the last two differ:

    * `:max_id` — strictly older than this id (the "load more" direction).
    * `:since_id` — newer than this id, still answering the **newest** page when
      more arrived than fit.
    * `:min_id` — newer than this id, answering the **oldest** of those instead,
      so a client can walk forward through a gap without skipping anything.

  `min_id` is what makes `restore/2` necessary: the page is fetched
  oldest-first to take the right end of the list, then handed back newest-first
  like every other page.
  """

  import Ecto.Query

  @default_limit 20

  @doc """
  Bounds and orders `query` by `field` (default `:id`) for one page.

  Any `order_by` and `limit` already on the query are **replaced**: the walk
  only holds together while the order matches the column the boundary is
  compared against, so a reader's own display order cannot be allowed to
  survive here. Callers whose natural order is something else (a bookmark list
  ordered by when it was saved, a profile ordered by repost time) therefore
  hand a client a list ordered by the id it walks by — which is the order
  Mastodon's own API guarantees, and the only one that can be walked at all.
  """
  def scope(query, opts, field \\ :id)

  def scope(query, opts, field) when is_atom(field) do
    query
    |> exclude(:order_by)
    |> exclude(:limit)
    |> boundary(opts[:max_id], fn q, id -> where(q, [r], field(r, ^field) < ^id) end)
    |> boundary(opts[:since_id], fn q, id -> where(q, [r], field(r, ^field) > ^id) end)
    |> boundary(opts[:min_id], fn q, id -> where(q, [r], field(r, ^field) > ^id) end)
    |> order_by([r], [{^direction(opts), field(r, ^field)}])
    |> limit(^page_size(opts))
  end

  # A list of accounts is usually selected through the edge that names them (a
  # like row, a follow row), so the id a client walks by belongs to a joined
  # binding rather than the first one. Naming that binding keeps the boundary
  # on the id the response actually carries — bounding the edge instead would
  # page one list while numbering another.
  def scope(query, opts, {binding, field}) do
    query
    |> exclude(:order_by)
    |> exclude(:limit)
    |> boundary(opts[:max_id], fn q, id ->
      where(q, [], field(as(^binding), ^field) < ^id)
    end)
    |> boundary(opts[:since_id], fn q, id ->
      where(q, [], field(as(^binding), ^field) > ^id)
    end)
    |> boundary(opts[:min_id], fn q, id ->
      where(q, [], field(as(^binding), ^field) > ^id)
    end)
    |> order_by([], [{^direction(opts), field(as(^binding), ^field)}])
    |> limit(^page_size(opts))
  end

  @doc "Restores newest-first after a `:min_id` page was fetched oldest-first."
  def restore(rows, opts) when is_list(rows) do
    if opts[:min_id], do: Enum.reverse(rows), else: rows
  end

  @doc """
  One page out of several sources that were each `scope/3`d by the same window.

  The in-memory half of the merged list this module's own note describes: no
  single query can order rows from two tables, but every id here is a
  `Vutuv.UUIDv7`, so sorting the union by id *is* sorting it by age. Each source
  is bounded first, so this cuts a page's worth of rows however deep the walk
  has gone — it is not the unbounded read the note warns about.

  Answers newest-first whichever boundary was asked for, so `restore/2` neither
  precedes nor follows it.
  """
  def merge(lists, opts) when is_list(lists) do
    lists
    |> Enum.concat()
    |> Enum.sort_by(& &1.id, :desc)
    |> take_page(opts)
  end

  @doc """
  Cuts an already-ordered, newest-first list to the page that was asked for.

  One owner for what the three boundaries mean at the *end* of a merged read:
  `:max_id` and `:since_id` want the newest of what is left, `:min_id` the
  **oldest** — which over a merged list is its tail rather than a reversal, so
  `restore/2` is the wrong tool and must not follow.
  `VutuvWeb.MastodonApi.Pagination.window/3` finishes with this too, having
  filtered rows that no query could bound.
  """
  def take_page(rows, opts) when is_list(rows) do
    limit = page_size(opts)

    if opts[:min_id], do: Enum.take(rows, -limit), else: Enum.take(rows, limit)
  end

  @doc "The page size a reader should ask for."
  def page_size(opts), do: Keyword.get(opts, :limit) || @default_limit

  defp direction(opts), do: if(opts[:min_id], do: :asc, else: :desc)

  defp boundary(query, nil, _fun), do: query
  defp boundary(query, id, fun), do: fun.(query, id)
end
