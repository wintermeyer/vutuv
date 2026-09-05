defmodule Vutuv.FeedPage do
  @moduledoc """
  Pagination for the merged multi-source feeds — the notification feed
  (`Vutuv.Activity.notifications_page/2`) and the post newsfeed
  (`Vutuv.Posts.feed_page/2`). Offset pagination of a single Ecto query (the
  browse pages) lives in `Vutuv.Pages`.

  Each source is a 2-arity fetch function `(fetch_n, cursor) -> [item]`
  returning maps that carry at least `:id` (unique across all sources) and
  `:at` (a `NaiveDateTime`). Both paginators merge the sources newest-first
  and return `%{entries:, more?:, next_cursor:}`.

  Two ways to walk such a feed:

    * `paginate/3` — **cursor**, for an endless "Load more" list that appends
      (the newsfeed, the API). The cursor is `%{at: timestamp, ids: [...]}` —
      the boundary timestamp plus every already-shown item id *at* that
      timestamp, and optionally `since:` — a **lower** bound that turns the walk
      into a window (the feed calendar's one-day view), and `since_basis:` —
      which of a source's clocks that window is measured on. `:arrival` asks the
      two fediverse sources for the moment a row reached *us* rather than the
      time its origin stamped on it minutes earlier
      (`Vutuv.Fediverse.window_clock/3`); anything else, its absence included,
      means the clock the source is ordered by. A source that honours `at` but
      forgets `since` does not crash, it silently widens, so any new source has
      to apply both — and one that forgets `since_basis` does not widen the
      window but *moves* it, which is quieter still. Timestamps have second
      precision, so several items (across all sources) can tie at a page
      boundary; fetching `<= at` and rejecting the seen ids means ties neither
      skip items nor repeat them. Treat the cursor as opaque.
    * `paginate_offset/3` — **offset**, for numbered pages you can jump
      between and link to (`/notifications?page=3`). There is no cursor to
      carry, so every source is fetched from the top and the merged list is
      dropped into; `next_cursor` is always nil.
  """

  @doc """
  The merged newest-first order, applied to `entries`.

  The single definition of the feed's ordering rule, so a caller that decorates
  a page and has to re-partition it (`Vutuv.Posts.feed_page/2` splits the cached
  remote posts off the local pipeline) restores exactly the order the paginators
  below handed over, instead of spelling the comparator out again.
  """
  def sort_entries(entries), do: Enum.sort_by(entries, & &1.at, {:desc, NaiveDateTime})

  @doc """
  Runs every source and returns what each one gave back, in the order the
  sources were listed.

  The one place a list of sources is turned into rows, so both paginators here
  and the feed calendar's counter (`Vutuv.Posts.feed_activity_by_day/4`, which
  merges nothing and only wants the lists) share one loop rather than each
  spelling out its own. Side by side, four at a time: the ten sources cost
  0.8 to 5.6 ms each and 31 ms in a row, and why four is `Vutuv.Concurrent`'s
  story.
  """
  def fetch_sources(sources, fetch_n, cursor) when is_list(sources) do
    Vutuv.Concurrent.run(Enum.map(sources, fn fetch -> fn -> fetch.(fetch_n, cursor) end end))
  end

  # Both paginators want the sources merged into one list; the only difference
  # is the cursor they pass on.
  defp fetch_all(sources, fetch_n, cursor) do
    sources |> fetch_sources(fetch_n, cursor) |> Enum.concat()
  end

  @doc """
  An entry cut down to the two fields the paginators actually read — a **mark**.

  This is the whole contract above, spelled as data: `paginate/3` and
  `sort_entries/1` touch `:id` and `:at` and nothing else, so a source asked to
  count rather than to draw may hand marks back instead of entries and every
  caller here is satisfied (`Vutuv.Posts.feed_sources/3`'s `:marks` shape,
  which is what the feed calendar's heatmap asks for).

  One definition rather than a `Map.take/2` at each site: the projection and
  the promise it rests on belong together, and a source that widens what a mark
  carries should widen it here.
  """
  def mark(entry), do: Map.take(entry, [:id, :at])

  def paginate(sources, limit, cursor) when is_list(sources) do
    seen = if cursor, do: cursor.ids, else: []

    # Over-fetch per source so that, after dropping the already-shown
    # boundary items, at least `limit + 1` candidates remain — the +1 is
    # what tells us whether another page exists.
    fetch_n = limit + length(seen) + 1

    candidates =
      sources
      |> fetch_all(fetch_n, cursor)
      |> Enum.reject(&(&1.id in seen))
      |> sort_entries()

    entries = Enum.take(candidates, limit)
    more? = length(candidates) > limit

    %{entries: entries, more?: more?, next_cursor: if(more?, do: next_cursor(entries, cursor))}
  end

  @doc """
  One numbered page (`offset` items in, `limit` long) of the merged feed.

  Every source is fetched from the top with `offset + limit + 1` rows, so the
  cost grows with how deep the reader pages — the trade for pages that can be
  linked to, jumped between and rendered with a numbered pager. `more?` says
  whether a further page exists; `next_cursor` is nil (an offset page needs no
  cursor, and returning the same shape keeps the two paginators swappable).
  """
  def paginate_offset(sources, limit, offset) when is_list(sources) and offset >= 0 do
    fetch_n = offset + limit + 1

    candidates =
      sources
      |> fetch_all(fetch_n, nil)
      |> sort_entries()

    %{
      entries: candidates |> Enum.drop(offset) |> Enum.take(limit),
      more?: length(candidates) > offset + limit,
      next_cursor: nil
    }
  end

  defp next_cursor([], _prev), do: nil

  defp next_cursor(entries, prev) do
    %{at: at} = List.last(entries)

    boundary_ids =
      entries
      |> Enum.filter(&(NaiveDateTime.compare(&1.at, at) == :eq))
      |> Enum.map(& &1.id)

    # When the boundary timestamp spans pages, carry the previous page's ids
    # at that timestamp along — they are still "already shown".
    carried = if prev && NaiveDateTime.compare(prev.at, at) == :eq, do: prev.ids, else: []

    # A window (`:since` and the clock it is read on) belongs to the whole walk,
    # not to one page, so it is carried rather than recomputed. Dropped here,
    # "Load more" inside a single day would silently widen to every earlier day
    # the moment the reader pressed it. Taken as one map so the two cannot come
    # apart: a `since` that arrives without its basis does not widen the window,
    # it moves it, page by page, with nothing on screen to show for it.
    %{at: at, ids: carried ++ boundary_ids}
    |> Map.merge(Map.take(prev || %{}, [:since, :since_basis]))
  end
end
