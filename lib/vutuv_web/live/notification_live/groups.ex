defmodule VutuvWeb.NotificationLive.Groups do
  @moduledoc """
  Pure presentation grouping behind the notifications page: raw
  `Vutuv.Activity` feed items in, calendar-day sections of cards out.

  The feed's event tables make one item per row, which floods the page - 113
  followers on one day were 113 identical cards. Grouping merges what reads
  as one piece of news, keyed within a calendar day — the **reader's** day
  (`Vutuv.ViewerClock`, issue #1502), like post timestamps. Since 2026-09 the
  key is the **subject**, not the verb:

    * everything about **one post** — likes, replies, mentions, answers deeper
      in its thread, and whatever another network sent back about it — is one
      **post card** (`kind: "post"`), headed by the post and carrying an
      `:events` list of lines: every reply keeps a line of its own, because it
      brings its own words; the likes merge into one line (local and fediverse
      alike, a globe on the name says where each came from), the re-shares into
      another. Measured on the real feed: 39 events on one day were about 11
      posts, and one post alone carried 16 of them — as verb-keyed rows the
      same post appeared three times, and every reply repeated its context.
    * the day's **people** events — followers, connections, endorsements — are
      one **people card** (`kind: "people"`) with one line per verb (followers
      merged, connections merged, one endorser's endorsements merged). A
      same-day mutual follow suppresses the redundant follower line: "is now
      connected" implies "follows you".

  Every rarer kind (moderation, CV updates, handle changes, the welcome note,
  ...) stays one row per event - each carries its own content.

  Within a day the cards with an **unanswered reply** come first, then the rest
  of what is new, then what the reader has seen; the page draws a "seen
  before" rule at that last transition. Everything here is a pure function over
  the item list, so the LiveView recomputes sections wholesale on every change
  (paging, live push, midnight rollover) instead of patching a stream in place.
  """

  alias Vutuv.ViewerClock

  # How many actors a line names before folding the rest into "and N more".
  @named_actors 2

  def named_actors, do: @named_actors

  # The kinds that are about one post and share its card. A thread answer is
  # about the thread's root (`root_post_id`), every other one names `post_id`.
  @post_kinds ~w(like reply mention fediverse_reaction fediverse_reply)
  @people_kinds ~w(follower connection endorsement)

  # The verbs that carry words of their own — a card with one of these unread
  # is what "unanswered" means, and what sorts a card to the top of its day.
  @reply_verbs [:reply, :thread, :mention, :remote_reply]

  @doc """
  The post an event is about — a thread answer's root, otherwise the post the
  event names — or nil for the kinds that get a row of their own. The one
  place that knows which field carries a kind's post id: the grouping keys
  on it, and the page builds its card heads from it.
  """
  def post_id_of(%{kind: "thread", root_post_id: id}) when is_binary(id), do: id
  def post_id_of(%{kind: kind, post_id: id}) when kind in @post_kinds and is_binary(id), do: id
  def post_id_of(_item), do: nil

  @doc "The event kinds a people card merges (`kind: \"people\"`)."
  def people_kinds, do: @people_kinds

  @doc "Whether a card line is a reply of some kind (it carries its own words)."
  def reply_verb?(%{verb: verb}), do: verb in @reply_verbs
  def reply_verb?(_line), do: false

  @doc """
  Group `items` into `[%{day: Date, groups: [group]}]`, newest day first.

  Each group carries `:id` (a stable DOM key), `:kind`, `:at` (its newest
  member's time), `:actors` (distinct, newest first), `:actor_count`,
  `:tags` (endorsement lines: chronological), `:item` (the newest raw item,
  for kind-specific fields and post previews), `:unread?` - true when any
  member is newer than `read_marker` (nil marker = everything unread) and not
  already marked `:seen?` by the caller (the reader engaged with the post the
  item is about, see `Vutuv.Activity.mark_post_seen/2`) - and `:unread_reply?`,
  true for a card holding an unread reply line.

  A post card (`kind: "post"`) also carries `:post_id` and `:events`, the
  lines; each line is a group of the same shape plus a `:verb` (`:reply`,
  `:thread`, `:mention`, `:remote_reply`, `:like`, `:share`, `:reaction`). A
  people card (`kind: "people"`) carries `:events` with the verbs `:follower`,
  `:connection` and `:endorsement`.
  """
  def sections(items, read_marker) do
    items
    |> Enum.map(&normalize/1)
    |> Enum.sort_by(&NaiveDateTime.to_iso8601(&1.at_naive), :desc)
    |> Enum.group_by(& &1.day)
    |> Enum.sort_by(fn {day, _} -> day end, {:desc, Date})
    |> Enum.map(fn {day, day_items} ->
      %{day: day, groups: day_groups(day, day_items, read_marker)}
    end)
  end

  # Merge one day's items into cards. `Enum.sort_by/3` is stable, so within
  # each of its three tiers the cards keep the newest-first order they were
  # bucketed in.
  defp day_groups(day, day_items, read_marker) do
    # "Is now connected with you" implies "follows you": when the same actor
    # has both events on one day (a mutual follow completed), the follower
    # item is redundant noise and the connection line alone tells the story.
    connected =
      day_items
      |> Enum.filter(&(&1.kind == "connection"))
      |> Enum.map(&actor_key/1)
      |> MapSet.new()

    day_items =
      Enum.reject(day_items, fn item ->
        item.kind == "follower" and MapSet.member?(connected, actor_key(item))
      end)

    day_items
    |> bucket(&group_key/1)
    |> Enum.map(fn {key, members} -> build_group(key, day, members, read_marker) end)
    |> Enum.sort_by(&{&1.unread_reply?, &1.unread?}, :desc)
  end

  # Bucket `items` by `key_fun` into `[{key, members}]`, both the buckets and
  # the members in the newest-first order they arrived in (`Enum.group_by`
  # keeps neither). Used twice: once to cut a day into cards, once more to cut
  # a card into one line per verb.
  defp bucket(items, key_fun) do
    {keys, members} =
      Enum.reduce(items, {[], %{}}, fn item, {keys, members} ->
        key = key_fun.(item)

        case members do
          %{^key => list} -> {keys, Map.put(members, key, [item | list])}
          _ -> {[key | keys], Map.put(members, key, [item])}
        end
      end)

    keys
    |> Enum.reverse()
    |> Enum.map(&{&1, Enum.reverse(members[&1])})
  end

  # What merges: everything about one post into its card, the day's people
  # events into the people card. Everything else is its own row.
  defp group_key(%{kind: kind}) when kind in @people_kinds, do: :people

  defp group_key(item) do
    case post_id_of(item) do
      nil -> {:single, item.id}
      post_id -> {:post, post_id}
    end
  end

  # A card is a group of groups: the head names the subject, and each of its
  # `:events` is an ordinary group built by the very same function one level
  # down. A post card's own `actors` are empty on purpose — every actor belongs
  # to one of the lines, and the card has no sentence of its own for them to be
  # the subject of; the people card keeps its actors, they are its avatar row.
  defp build_group({:post, post_id} = key, day, members, read_marker) do
    events =
      members
      |> bucket(&line_key(post_id, &1))
      |> Enum.map(fn {line, line_members} -> build_line(line, day, line_members, read_marker) end)
      |> Enum.sort_by(&line_rank/1)

    key
    |> base_group(day, members, read_marker)
    |> Map.merge(%{
      kind: "post",
      post_id: post_id,
      actors: [],
      actor_count: 0,
      events: events,
      unread_reply?: Enum.any?(events, &(reply_verb?(&1) and &1.unread?))
    })
  end

  defp build_group(:people = key, day, members, read_marker) do
    events =
      members
      |> bucket(&people_line_key/1)
      |> Enum.map(fn {line, line_members} -> build_line(line, day, line_members, read_marker) end)

    key
    |> base_group(day, members, read_marker)
    |> Map.merge(%{kind: "people", events: events, unread_reply?: false})
  end

  defp build_group(key, day, members, read_marker),
    do: key |> base_group(day, members, read_marker) |> Map.put(:unread_reply?, false)

  # One line per verb inside a post card: the likes merge into one — a member's
  # like and a favourite from another network are the same verb — the
  # re-shares into another, and every reply keeps its own line, because each
  # carries its own words. The keys are the same ones a row used to have, so
  # the ids stay what they were before the card existed.
  defp line_key(post_id, %{kind: "like"}), do: {:like, post_id}

  defp line_key(post_id, %{kind: "fediverse_reaction", reaction_kind: "like"}),
    do: {:like, post_id}

  defp line_key(post_id, %{kind: "fediverse_reaction", reaction_kind: "announce"}),
    do: {:share, post_id}

  defp line_key(post_id, %{kind: "fediverse_reaction", reaction_kind: reaction_kind})
       when is_binary(reaction_kind),
       do: {:reaction, post_id, reaction_kind}

  defp line_key(_post_id, item), do: {:single, item.id}

  defp people_line_key(%{kind: "follower"}), do: :follower
  defp people_line_key(%{kind: "connection"}), do: :connection
  defp people_line_key(%{kind: "endorsement"} = item), do: {:endorsement, actor_key(item)}

  defp build_line(key, day, members, read_marker) do
    key
    |> base_group(day, members, read_marker)
    |> Map.put(:verb, verb(key, hd(members)))
  end

  defp verb({:like, _post_id}, _newest), do: :like
  defp verb({:share, _post_id}, _newest), do: :share
  defp verb({:reaction, _post_id, _kind}, _newest), do: :reaction
  defp verb(:follower, _newest), do: :follower
  defp verb(:connection, _newest), do: :connection
  defp verb({:endorsement, _actor}, _newest), do: :endorsement
  defp verb({:single, _id}, %{kind: "reply"}), do: :reply
  defp verb({:single, _id}, %{kind: "thread"}), do: :thread
  defp verb({:single, _id}, %{kind: "mention"}), do: :mention
  defp verb({:single, _id}, %{kind: "fediverse_reply"}), do: :remote_reply
  defp verb({:single, _id}, _newest), do: :other

  # Replies lead (each newest-first, as bucketed), then the like line, then the
  # re-shares, then any other reaction kind.
  defp line_rank(%{verb: verb}) when verb in @reply_verbs, do: 0
  defp line_rank(%{verb: :like}), do: 1
  defp line_rank(%{verb: :share}), do: 2
  defp line_rank(_line), do: 3

  # `members` arrive newest-first.
  defp base_group(key, day, members, read_marker) do
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
  defp group_id({:post, post_id}, day, _newest), do: "post-#{post_id}-#{day_key(day)}"
  defp group_id(:people, day, _newest), do: "people-#{day_key(day)}"
  defp group_id({:like, post_id}, day, _newest), do: "like-#{post_id}-#{day_key(day)}"
  defp group_id({:share, post_id}, day, _newest), do: "share-#{post_id}-#{day_key(day)}"

  defp group_id({:reaction, post_id, reaction_kind}, day, _newest),
    do: "reaction-#{reaction_kind}-#{post_id}-#{day_key(day)}"

  defp group_id(:follower, day, _newest), do: "follower-#{day_key(day)}"
  defp group_id(:connection, day, _newest), do: "connection-#{day_key(day)}"

  defp group_id({:endorsement, actor_key}, day, _newest),
    do: "endorsement-#{actor_key}-#{day_key(day)}"

  defp day_key(day), do: Date.to_iso8601(day, :basic)

  # An endorsement line's tag names in the order they were given (name as a
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
        # to, so the line links out to their account instead and names them by
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
  # name would fold into a single line.
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
  # DateTimes, derived rows NaiveDateTimes) and the reader's calendar day.
  defp normalize(item) do
    at = to_naive(item[:at]) || NaiveDateTime.utc_now(:second)

    item
    |> Map.put(:at_naive, at)
    |> Map.put(:day, ViewerClock.date(at))
  end

  defp to_naive(%DateTime{} = at), do: DateTime.to_naive(at)
  defp to_naive(%NaiveDateTime{} = at), do: at
  defp to_naive(_), do: nil
end
