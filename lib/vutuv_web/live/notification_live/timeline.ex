defmodule VutuvWeb.NotificationLive.Timeline do
  @moduledoc """
  The notifications page as one timeline: raw `Vutuv.Activity` feed items and
  the member's own visits in, the blocks the page draws out.

  **A visit is a line.** Every time the member opened the page (or closed the
  bell's preview) is drawn where it happened, "You were here · 14:02", so what
  arrived between two looks sits between two lines. That is the whole answer
  to "I looked at 14:00, came back at 18:00 and lost track": the read marker
  only knows the last look and moves on every glance, the lines keep all of
  them.

  Between two lines and within one of the reader's calendar days (a
  **section**):

    * every item that carries somebody's words (a reply, a thread answer, a
      mention, a reply from another network) is a `:words` row of its own;
    * likes and re-shares of one post are one `:reactions` row;
    * followers and connections are one `:people` row, a follower and the
      connection that followed a moment later being one person;
    * everything rarer is an `:other` row per event.

  What is newer than `new_since` (the visit before this one) and not already
  dealt with (`:seen?`) is **fresh**; the first fresh row is announced by a
  `:fresh` block. A pure function over the item list, so the LiveView rebuilds
  it wholesale on every change.
  """

  alias Vutuv.ViewerClock

  @words_kinds ~w(reply thread mention fediverse_reply)
  @reaction_kinds ~w(like fediverse_reaction)
  @people_kinds ~w(follower connection)

  @doc """
  The blocks, newest first:

    * `{:day, date}` — a day heading;
    * `{:fresh, count, since}` — before the first fresh row;
    * `{:visits, [visit]}` — one line for one or more adjacent visits;
    * `{:row, row}` — a row, `row.type` one of `:words`, `:reactions`,
      `:people`, `:other`.

  `visits` are `%{at: NaiveDateTime (UTC), source: "page" | "bell"}`.
  """
  def build(items, visits, opts \\ []) do
    new_since = Keyword.get(opts, :new_since)
    replies_only? = Keyword.get(opts, :replies_only?, false)

    visits = Enum.sort_by(visits, & &1.at, NaiveDateTime)

    rows =
      items
      |> Enum.map(&normalize/1)
      |> Enum.filter(&(not replies_only? or &1.kind in @words_kinds))
      |> Enum.group_by(&section_key(&1, visits))
      |> Enum.flat_map(fn {key, members} -> section_rows(key, members, new_since) end)

    marks = Enum.map(visits, &{:visit, &1})

    (Enum.map(rows, &{:row, &1}) ++ marks)
    |> Enum.sort(&newer?/2)
    |> emit(Enum.count(rows, & &1.fresh?), new_since)
  end

  # Rows above a line at the same second: an event stamped in the very second
  # of a visit was not on screen yet.
  defp newer?(a, b) do
    case NaiveDateTime.compare(at(a), at(b)) do
      :gt -> true
      :lt -> false
      :eq -> match?({:row, _}, a) or match?({:visit, _}, b)
    end
  end

  defp at({:row, row}), do: row.at
  defp at({:visit, visit}), do: visit.at

  defp emit(sorted, fresh_count, new_since) do
    {blocks, state} =
      Enum.reduce(sorted, {[], %{day: nil, visits: [], fresh_shown?: false}}, fn
        {:visit, visit}, {blocks, state} ->
          {blocks, state} = day(blocks, state, ViewerClock.date(visit.at))
          {blocks, %{state | visits: [visit | state.visits]}}

        {:row, row}, {blocks, state} ->
          {blocks, state} = day(blocks, state, row.day)
          {blocks, state} = flush_visits(blocks, state)

          {blocks, state} =
            if row.fresh? and not state.fresh_shown? do
              {[{:fresh, fresh_count, new_since} | blocks], %{state | fresh_shown?: true}}
            else
              {blocks, state}
            end

          {[{:row, row} | blocks], state}
      end)

    {blocks, _state} = flush_visits(blocks, state)
    Enum.reverse(blocks)
  end

  defp day(blocks, %{day: day} = state, day), do: {blocks, state}

  defp day(blocks, state, day) do
    {blocks, state} = flush_visits(blocks, state)
    {[{:day, day} | blocks], %{state | day: day}}
  end

  defp flush_visits(blocks, %{visits: []} = state), do: {blocks, state}

  # Collected newest first, so the list already reads oldest to newest.
  defp flush_visits(blocks, state),
    do: {[{:visits, state.visits} | blocks], %{state | visits: []}}

  # The section an item sits in: its reader's day, and the first visit after
  # it (`:new` when no visit has happened since).
  defp section_key(item, visits) do
    seen_by = Enum.find_index(visits, &(NaiveDateTime.compare(&1.at, item.at) == :gt))
    {item.day, seen_by || :new}
  end

  defp section_rows({day, seen_by}, members, new_since) do
    suffix = "#{Date.to_iso8601(day, :basic)}-#{seen_by}"
    {reactions, rest} = Enum.split_with(members, &(&1.kind in @reaction_kinds))
    {people, rest} = Enum.split_with(rest, &(&1.kind in @people_kinds))

    single =
      Enum.map(rest, fn item ->
        type = if item.kind in @words_kinds, do: :words, else: :other
        row(type, item.id, [item], day, new_since, %{item: item})
      end)

    bundled =
      reactions
      |> Enum.group_by(& &1[:post_id])
      |> Enum.map(fn {post_id, likes} ->
        row(:reactions, "reactions-#{post_id}-#{suffix}", likes, day, new_since, %{
          post_id: post_id,
          actors: distinct_actors(likes),
          likes: count_actors(likes, &like?/1),
          shares: count_actors(likes, &share?/1)
        })
      end)

    persons =
      if people == [] do
        []
      else
        [
          row(:people, "people-#{suffix}", people, day, new_since, %{
            persons: persons(people)
          })
        ]
      end

    single ++ bundled ++ persons
  end

  defp row(type, id, members, day, new_since, fields) do
    Map.merge(fields, %{
      type: type,
      id: id,
      day: day,
      at: members |> Enum.map(& &1.at) |> Enum.max(NaiveDateTime),
      fresh?: Enum.any?(members, &fresh?(&1, new_since))
    })
  end

  defp fresh?(%{seen?: true}, _new_since), do: false
  defp fresh?(_item, nil), do: false
  defp fresh?(item, new_since), do: NaiveDateTime.compare(item.at, new_since) == :gt

  defp like?(%{kind: "like"}), do: true
  defp like?(%{kind: "fediverse_reaction"} = item), do: item[:reaction_kind] != "announce"
  defp like?(_item), do: false

  defp share?(%{kind: "fediverse_reaction", reaction_kind: "announce"}), do: true
  defp share?(_item), do: false

  defp count_actors(items, fun),
    do: items |> Enum.filter(fun) |> Enum.uniq_by(&actor_key/1) |> length()

  # One person per actor, newest first: "follows you" and "you are connected"
  # arrive as two events a moment apart and are one piece of news.
  defp persons(people) do
    people
    |> Enum.group_by(&actor_key/1)
    |> Enum.map(fn {_key, events} ->
      newest = Enum.max_by(events, & &1.at, NaiveDateTime)

      newest
      |> actor()
      |> Map.merge(%{
        at: newest.at,
        connected?: Enum.any?(events, &(&1.kind == "connection"))
      })
    end)
    |> Enum.sort_by(& &1.at, {:desc, NaiveDateTime})
  end

  # One entry per person, newest first, saying what they did: the reactions
  # row lists them with a heart, the re-share arrows, or both.
  defp distinct_actors(items) do
    items
    |> Enum.sort_by(& &1.at, {:desc, NaiveDateTime})
    |> Enum.group_by(&actor_key/1)
    |> Enum.map(fn {_key, [newest | _] = theirs} ->
      newest
      |> actor()
      |> Map.merge(%{
        at: newest.at,
        liked?: Enum.any?(theirs, &like?/1),
        shared?: Enum.any?(theirs, &share?/1)
      })
    end)
    |> Enum.sort_by(& &1.at, {:desc, NaiveDateTime})
  end

  @doc "The actor an item names, in the shape the page links."
  def actor(item) do
    %{
      id: item[:actor_id],
      name: item[:actor_name],
      param: item[:actor_param],
      kind: item[:actor_kind],
      avatar: item[:actor_avatar],
      url: item[:actor_url],
      handle: item[:actor_handle]
    }
  end

  # One stable identity per actor: their id, their remote account, their
  # handle here, and only as a last resort their display name.
  defp actor_key(item) do
    item[:actor_id] || item[:actor_url] || item[:actor_param] ||
      "anon-#{:erlang.phash2(item[:actor_name])}"
  end

  # Pushed events carry DateTimes, derived rows NaiveDateTimes; every item
  # leaves with UTC naive `at` and the reader's calendar day.
  defp normalize(item) do
    at = to_naive(item[:at]) || NaiveDateTime.utc_now(:second)

    item
    |> Map.put(:at, at)
    |> Map.put(:day, ViewerClock.date(at))
  end

  defp to_naive(%DateTime{} = at),
    do: at |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)

  defp to_naive(%NaiveDateTime{} = at), do: NaiveDateTime.truncate(at, :second)
  defp to_naive(_other), do: nil
end
