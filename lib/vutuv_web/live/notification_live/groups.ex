defmodule VutuvWeb.NotificationLive.Groups do
  @moduledoc """
  Pure presentation grouping behind the notifications page: raw
  `Vutuv.Activity` feed items in, Berlin-day sections of merged rows out.

  The feed's event tables make one item per row, which floods the page - 113
  followers on one day were 113 identical cards. Grouping merges what reads
  as one piece of news into one row, keyed within a Berlin calendar day (the
  site's canonical clock, like post timestamps):

    * likes of the **same post** - "Anna and Ben liked your post."
    * new **followers** - "Anna, Ben and 111 more are now following you."
    * new **connections** (mutual follows) - same day-bucket rule
    * one endorser's **endorsements** - "endorsed you for Elixir and Phoenix."
    * **thread** events of the same thread - "Anna and Ben replied in a
      thread you posted in."
    * **reactions from other networks** to the same post, per kind -
      "@anna@chaos.social and @ben@social.example shared your post."

  Direct replies, mentions and every rarer kind (moderation, CV updates,
  handle changes, ...) stay one row per event - each carries its own content.

  Everything here is a pure function over the item list, so the LiveView
  recomputes sections wholesale on every change (load more, live push,
  midnight rollover) instead of patching a stream in place.
  """

  alias Vutuv.BerlinTime

  # How many actors a row names before folding the rest into "and N more".
  @named_actors 2

  def named_actors, do: @named_actors

  @doc """
  Group `items` into `[%{day: Date, groups: [group]}]`, newest day first.

  Each group carries `:id` (a stable DOM key), `:kind`, `:at` (its newest
  member's time), `:actors` (distinct, newest first), `:actor_count`,
  `:tags` (endorsement groups: chronological), `:item` (the newest raw item,
  for kind-specific fields and post previews) and `:unread?` - true when any
  member is newer than `read_marker` (nil marker = everything unread) and not
  already marked `:seen?` by the caller (the reader engaged with the post the
  item is about, see `Vutuv.Activity.mark_post_seen/2`).
  """
  def sections(items, read_marker) do
    items
    |> Enum.map(&normalize/1)
    |> Enum.sort_by(&NaiveDateTime.to_iso8601(&1.at_naive), :desc)
    |> Enum.group_by(& &1.berlin_day)
    |> Enum.sort_by(fn {day, _} -> day end, {:desc, Date})
    |> Enum.map(fn {day, day_items} ->
      %{day: day, groups: day_groups(day, day_items, read_marker)}
    end)
  end

  # Merge one day's items into rows, preserving newest-first order of first
  # appearance (Enum.group_by would lose it).
  defp day_groups(day, day_items, read_marker) do
    # "Is now connected with you" implies "follows you": when the same actor
    # has both events on one day (a mutual follow completed), the follower
    # item is redundant noise and the connection row alone tells the story.
    connected =
      day_items
      |> Enum.filter(&(&1.kind == "connection"))
      |> Enum.map(&actor_key/1)
      |> MapSet.new()

    day_items =
      Enum.reject(day_items, fn item ->
        item.kind == "follower" and MapSet.member?(connected, actor_key(item))
      end)

    {keys, members} =
      Enum.reduce(day_items, {[], %{}}, fn item, {keys, members} ->
        key = group_key(item)

        case members do
          %{^key => list} -> {keys, Map.put(members, key, [item | list])}
          _ -> {[key | keys], Map.put(members, key, [item])}
        end
      end)

    keys
    |> Enum.reverse()
    |> Enum.map(fn key ->
      build_group(key, day, Enum.reverse(members[key]), read_marker)
    end)
  end

  # What merges: same-day likes per post, same-day followers/connections as
  # one bucket each, one endorser's same-day endorsements. Everything else is
  # its own row.
  defp group_key(%{kind: "like", post_id: post_id}) when is_binary(post_id),
    do: {:like, post_id}

  defp group_key(%{kind: "thread", root_post_id: root_id}) when is_binary(root_id),
    do: {:thread, root_id}

  # Reactions from other networks merge per post *and per kind*: a favourite and
  # a re-share are different news, and one row can only carry one verb.
  defp group_key(%{kind: "fediverse_reaction", post_id: post_id, reaction_kind: reaction_kind})
       when is_binary(post_id) and is_binary(reaction_kind),
       do: {:fediverse_reaction, post_id, reaction_kind}

  defp group_key(%{kind: "follower"}), do: :follower
  defp group_key(%{kind: "connection"}), do: :connection
  defp group_key(%{kind: "endorsement"} = item), do: {:endorsement, actor_key(item)}
  defp group_key(item), do: {:single, item.id}

  # `members` arrive newest-first.
  defp build_group(key, day, members, read_marker) do
    newest = hd(members)
    actors = distinct_actors(members)

    %{
      id: group_id(key, day, newest),
      kind: newest.kind,
      at: newest.at_naive,
      actors: actors,
      actor_count: length(actors),
      tags: group_tags(newest.kind, members),
      item: newest,
      unread?: Enum.any?(members, &unread?(&1, read_marker))
    }
  end

  defp group_id({:single, id}, _day, _newest), do: id
  defp group_id({:like, post_id}, day, _newest), do: "like-#{post_id}-#{day_key(day)}"
  defp group_id({:thread, root_id}, day, _newest), do: "thread-#{root_id}-#{day_key(day)}"

  defp group_id({:fediverse_reaction, post_id, reaction_kind}, day, _newest),
    do: "fediverse-reaction-#{reaction_kind}-#{post_id}-#{day_key(day)}"

  defp group_id(:follower, day, _newest), do: "follower-#{day_key(day)}"
  defp group_id(:connection, day, _newest), do: "connection-#{day_key(day)}"

  defp group_id({:endorsement, actor_key}, day, _newest),
    do: "endorsement-#{actor_key}-#{day_key(day)}"

  defp day_key(day), do: Date.to_iso8601(day, :basic)

  # An endorsement group's tag names in the order they were given (name as a
  # deterministic tiebreaker for the second-precision timestamps).
  defp group_tags("endorsement", members) do
    members
    |> Enum.sort_by(&{NaiveDateTime.to_iso8601(&1.at_naive), &1[:tag]})
    |> Enum.map(& &1[:tag])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp group_tags(_kind, _members), do: nil

  # Distinct actors, newest first. Items without an actor (moderation, image
  # review) contribute none.
  defp distinct_actors(members) do
    members
    |> Enum.filter(& &1[:actor_name])
    |> Enum.uniq_by(&actor_key/1)
    |> Enum.map(
      &%{
        id: &1[:actor_id],
        name: &1[:actor_name],
        param: &1[:actor_param],
        # Which namespace `param` belongs to (issue #1336): a member's handle
        # lives at the root, a page's slug under /organizations/:slug.
        kind: &1[:actor_kind],
        avatar: &1[:actor_avatar],
        # Somebody on another network (issue #1069): no vutuv profile to link
        # to, so the row links out to their account instead and names them by
        # their `@handle@host`.
        url: &1[:actor_url],
        handle: &1[:actor_handle]
      }
    )
  end

  # One stable identity per actor: their id when we have it, then their remote
  # account URL, then their route param, and only as a last resort a hash of the
  # display name (live-pushed test payloads carry bare maps). The remote URL
  # matters — without it two different strangers who happen to share a display
  # name would fold into a single row.
  defp actor_key(item) do
    item[:actor_id] || item[:actor_url] || item[:actor_param] ||
      "anon-#{:erlang.phash2(item[:actor_name])}"
  end

  # An item the reader already engaged with (`:seen?`, set by the page from
  # `Vutuv.Activity.mark_post_seen/2`) is read whatever the marker says: they
  # answered, liked, bookmarked or reposted the post it is about, and the shell
  # badge stopped counting it there and then.
  defp unread?(%{seen?: true}, _read_marker), do: false
  defp unread?(_item, nil), do: true

  defp unread?(item, read_marker),
    do: NaiveDateTime.compare(item.at_naive, read_marker) == :gt

  # Every item gets a normalized UTC NaiveDateTime (pushed events carry
  # DateTimes, derived rows NaiveDateTimes) and its Berlin calendar day.
  defp normalize(item) do
    at = to_naive(item[:at]) || NaiveDateTime.utc_now(:second)

    item
    |> Map.put(:at_naive, at)
    |> Map.put(:berlin_day, at |> DateTime.from_naive!("Etc/UTC") |> BerlinTime.date())
  end

  defp to_naive(%DateTime{} = at), do: DateTime.to_naive(at)
  defp to_naive(%NaiveDateTime{} = at), do: at
  defp to_naive(_), do: nil
end
