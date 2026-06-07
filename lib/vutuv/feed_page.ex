defmodule Vutuv.FeedPage do
  @moduledoc """
  Cursor pagination for the merged multi-source feeds — the notification feed
  (`Vutuv.Activity.notifications_page/2`) and the post newsfeed
  (`Vutuv.Posts.feed_page/2`). Offset pagination for browse pages lives in
  `Vutuv.Pages`.

  Each source is a 2-arity fetch function `(fetch_n, cursor) -> [item]`
  returning maps that carry at least `:id` (unique across all sources) and
  `:at` (a `NaiveDateTime`). `paginate/3` merges the sources newest-first and
  returns `%{entries:, more?:, next_cursor:}`.

  The cursor is `%{at: timestamp, ids: [...]}` — the boundary timestamp plus
  every already-shown item id *at* that timestamp. Timestamps have second
  precision, so several items (across all sources) can tie at a page
  boundary; fetching `<= at` and rejecting the seen ids means ties neither
  skip items nor repeat them. Treat the cursor as opaque.
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
