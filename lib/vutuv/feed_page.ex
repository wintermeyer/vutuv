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
      timestamp. Timestamps have second precision, so several items (across
      all sources) can tie at a page boundary; fetching `<= at` and rejecting
      the seen ids means ties neither skip items nor repeat them. Treat the
      cursor as opaque.
    * `paginate_offset/3` — **offset**, for numbered pages you can jump
      between and link to (`/notifications?page=3`). There is no cursor to
      carry, so every source is fetched from the top and the merged list is
      dropped into; `next_cursor` is always nil.
  """

  def paginate(sources, limit, cursor) when is_list(sources) do
    seen = if cursor, do: cursor.ids, else: []

    # Over-fetch per source so that, after dropping the already-shown
    # boundary items, at least `limit + 1` candidates remain — the +1 is
    # what tells us whether another page exists.
    fetch_n = limit + length(seen) + 1

    candidates =
      sources
      |> Enum.flat_map(fn fetch -> fetch.(fetch_n, cursor) end)
      |> Enum.reject(&(&1.id in seen))
      |> Enum.sort_by(& &1.at, {:desc, NaiveDateTime})

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
      |> Enum.flat_map(fn fetch -> fetch.(fetch_n, nil) end)
      |> Enum.sort_by(& &1.at, {:desc, NaiveDateTime})

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

    %{at: at, ids: carried ++ boundary_ids}
  end
end
