defmodule Vutuv.Activity do
  @moduledoc """
  In-app activity: the real-time bus plus the derived notifications feed.

  The bus is a thin wrapper over `Phoenix.PubSub` (`Vutuv.PubSub`) used to push
  live updates to a user's open sessions: new follower / endorsement /
  connection bump the notification badge, new messages bump the message badge.
  This is **not** email — outbound mail still goes through
  `Vutuv.Notifications.Emailer`. Topic per user is `"user:<id>"`. The shell
  (`VutuvWeb.ShellLive`) and the notification / message LiveViews subscribe.

  The feed is **derived at read time** from the event tables that already exist
  (`connections`, `user_tag_endorsements`) instead of being persisted per
  notification — which makes it automatically retroactive. The only stored
  state is `users.notifications_read_at`, the read marker behind the unread
  badge; `mark_notifications_read/1` bumps it and broadcasts. Older events are
  reached via `notifications_page/2`, a timestamp-cursor pagination that backs
  the "Load more" button.
  """
  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.Social.Connection
  alias Vutuv.Tags.UserTagEndorsement

  @pubsub Vutuv.PubSub
  @default_limit 50

  def topic(user_id), do: "user:#{user_id}"

  def subscribe(nil), do: :ok
  def subscribe(user_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(user_id))

  @doc "Broadcast a raw event to a user's topic (no-op for a nil recipient)."
  def broadcast(nil, _event), do: :ok
  def broadcast(user_id, event), do: Phoenix.PubSub.broadcast(@pubsub, topic(user_id), event)

  @doc """
  Persist the read marker (`users.notifications_read_at`) and tell the user's
  shell their notifications were just read (clears the badge).
  """
  def mark_notifications_read(nil), do: :ok

  def mark_notifications_read(user_id) do
    Repo.update_all(
      from(u in User, where: u.id == ^user_id),
      set: [notifications_read_at: read_marker(user_id)]
    )

    broadcast(user_id, :notifications_read)
  end

  # The read marker is the timestamp of the newest feed event the user has seen,
  # not the wall clock. The event tables only keep second precision, and unread
  # counting uses a strict `>`, so a wall-clock marker would swallow any event
  # that happens to land in the same second the user opened the page. Anchoring
  # the marker to the last seen event keeps such same-second arrivals unread.
  # With no events yet there is nothing newer to miss, so the wall clock is
  # fine (and beats a NULL marker, which would mean "never read").
  defp read_marker(user_id) do
    latest_event_at(user_id) || NaiveDateTime.utc_now(:second)
  end

  defp latest_event_at(user_id) do
    follower_max =
      from(c in Connection, where: c.followee_id == ^user_id, select: max(c.inserted_at))
      |> Repo.one()

    endorsement_max =
      from(e in UserTagEndorsement,
        join: ut in assoc(e, :user_tag),
        where: ut.user_id == ^user_id and e.user_id != ^user_id,
        select: max(e.inserted_at)
      )
      |> Repo.one()

    connection_max =
      from(c in Connection,
        join: r in Connection,
        on: r.follower_id == c.followee_id and r.followee_id == c.follower_id,
        where: c.followee_id == ^user_id,
        select: max(fragment("GREATEST(?, ?)", c.inserted_at, r.inserted_at))
      )
      |> Repo.one()

    [follower_max, endorsement_max, connection_max]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(NaiveDateTime, fn -> nil end)
  end

  @doc "Tell a user's shell their messages were just read (clears the badge)."
  def mark_messages_read(user_id), do: broadcast(user_id, :messages_read)

  @doc "Push a new in-app notification to `user_id`."
  def notify(nil, _notification), do: :ok

  def notify(user_id, %{} = notification),
    do: broadcast(user_id, {:new_notification, notification})

  @doc """
  Convenience: a "started following you" notification for the followee. Carries
  the actor's name, route param, and avatar so the notifications page can link
  to the follower's profile and show their picture.
  """
  def notify_new_follower(followee_id, follower) do
    notify(
      followee_id,
      Map.merge(actor_fields(follower), %{
        kind: "follower",
        text: "started following you.",
        at: DateTime.utc_now()
      })
    )
  end

  @doc ~S(Convenience: an "endorsed you for <tag>" notification for the tag's owner.)
  def notify_endorsement(owner_id, endorser, tag_name) do
    notify(
      owner_id,
      Map.merge(actor_fields(endorser), %{
        kind: "endorsement",
        tag: tag_name,
        text: "endorsed you for #{tag_name}.",
        at: DateTime.utc_now()
      })
    )
  end

  @doc ~S(Convenience: an "is now connected with you" notification after a mutual follow.)
  def notify_connection(user_id, other) do
    notify(
      user_id,
      Map.merge(actor_fields(other), %{
        kind: "connection",
        text: "is now connected with you.",
        at: DateTime.utc_now()
      })
    )
  end

  ## Derived notifications feed

  @doc """
  The user's notification feed, newest first: followers (`connections`),
  endorsements (`user_tag_endorsements`, with the tag's name) and mutual
  connections (a reciprocal pair of `connections` rows, timestamped at the
  later of the two). Derived straight from those tables, so it includes
  events from before this feature existed. Items mirror the live
  `notify_*` payload shape; ids are `"<kind>-<row id>"` strings, which keeps
  them out of the `"live-"` id namespace the LiveView uses for pushed events.
  """
  def recent_notifications(user_id, limit \\ @default_limit) do
    notifications_page(user_id, limit: limit).entries
  end

  @doc """
  One page of the feed plus pagination state for a "Load more" UI:
  `%{entries: [...], more?: boolean, next_cursor: cursor | nil}`. Pass the
  returned cursor back as `cursor:` to get the next-older page.

  The cursor is `%{at: timestamp, ids: [...]}` — the boundary timestamp plus
  every already-shown event id *at* that timestamp. Timestamps have second
  precision, so several events (across all three source tables) can tie at a
  page boundary; filtering by `<= at` and rejecting the seen ids means ties
  neither skip events nor repeat them. Treat the cursor as opaque.
  """
  def notifications_page(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    cursor = Keyword.get(opts, :cursor)
    seen = if cursor, do: cursor.ids, else: []

    # Over-fetch per source so that, after dropping the already-shown
    # boundary events, at least `limit + 1` candidates remain — the +1 is
    # what tells us whether another page exists.
    fetch = limit + length(seen) + 1

    candidates =
      (follower_items(user_id, fetch, cursor) ++
         endorsement_items(user_id, fetch, cursor) ++ connection_items(user_id, fetch, cursor))
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

  @doc """
  The size of the whole derived feed, read marker ignored. Backs the
  "Load N of M more" label under the feed. Zero for a logged-out visitor.
  """
  def notifications_count(nil), do: 0

  def notifications_count(user_id), do: total_count(user_id, nil)

  @doc """
  How many feed events are newer than the user's read marker (all of them when
  the marker is NULL). Zero for a logged-out visitor.
  """
  def unread_notification_count(nil), do: 0

  def unread_notification_count(user_id) do
    read_at = Repo.one(from(u in User, where: u.id == ^user_id, select: u.notifications_read_at))
    total_count(user_id, read_at)
  end

  # The three feed sources are counted in a single round trip: each count is a
  # scalar subquery, summed in one SELECT. unread_notification_count/1 still
  # needs one prior read for the marker, so it ends up at 2 queries (was 4);
  # notifications_count/1 needs no marker and so runs in 1 query (was 3). The
  # strict `> read_at` unread filter and the GREATEST-anchored mutuality
  # timestamp are unchanged — only the round trips collapse.
  defp total_count(user_id, read_at) do
    Repo.one(
      from(s in subquery(count_followers(user_id, read_at)),
        select:
          s.count + subquery(count_endorsements(user_id, read_at)) +
            subquery(count_connections(user_id, read_at))
      )
    )
  end

  defp follower_items(user_id, limit, cursor) do
    from(c in Connection,
      where: c.followee_id == ^user_id,
      join: f in assoc(c, :follower),
      order_by: [desc: c.inserted_at, desc: c.id],
      limit: ^limit,
      select: {c.id, c.inserted_at, f}
    )
    |> at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, follower} ->
      actor_item("follower-#{id}", "follower", at, follower)
    end)
  end

  defp endorsement_items(user_id, limit, cursor) do
    from(e in UserTagEndorsement,
      join: ut in assoc(e, :user_tag),
      join: t in assoc(ut, :tag),
      join: endorser in assoc(e, :user),
      # Self-endorsements are possible in old data; they are not news.
      where: ut.user_id == ^user_id and e.user_id != ^user_id,
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: ^limit,
      select: {e.id, e.inserted_at, endorser, t.name}
    )
    |> at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, endorser, tag_name} ->
      "endorsement-#{id}"
      |> actor_item("endorsement", at, endorser)
      |> Map.put(:tag, tag_name)
    end)
  end

  defp connection_items(user_id, limit, cursor) do
    query =
      from(c in Connection,
        join: r in Connection,
        on: r.follower_id == c.followee_id and r.followee_id == c.follower_id,
        where: c.followee_id == ^user_id,
        join: f in assoc(c, :follower),
        order_by: [desc: fragment("GREATEST(?, ?)", c.inserted_at, r.inserted_at), desc: c.id],
        limit: ^limit,
        select: {c.id, fragment("GREATEST(?, ?)", c.inserted_at, r.inserted_at), f}
      )

    query =
      if cursor do
        # The mutuality event happens at the later of the two follows.
        where(
          query,
          [c, r],
          fragment("GREATEST(?, ?) <= ?", c.inserted_at, r.inserted_at, ^cursor.at)
        )
      else
        query
      end

    query
    |> Repo.all()
    |> Enum.map(fn {id, at, friend} ->
      actor_item("connection-#{id}", "connection", at, friend)
    end)
  end

  defp at_or_before(query, nil), do: query
  defp at_or_before(query, %{at: at}), do: where(query, [event], event.inserted_at <= ^at)

  defp actor_item(id, kind, at, actor) do
    Map.merge(actor_fields(actor), %{id: id, kind: kind, at: at})
  end

  # The actor triple (name / route param / avatar) that the live `notify_*`
  # payloads and the derived feed items must carry identically. Both sides merge
  # their own kind/text/at (and :tag for endorsements) onto this, so the shapes
  # stay in lock-step. Accepts a bare map too: the activity tests pass plain
  # maps as actors, where only the name is derivable.
  defp actor_fields(actor) do
    %{
      actor_name: display_name(actor),
      actor_param: actor_param(actor),
      actor_avatar: actor_avatar(actor)
    }
  end

  # Each count helper returns a query selecting a single count, so total_count/2
  # can fold all three into one round trip via scalar subqueries.
  defp count_followers(user_id, read_at) do
    from(c in Connection, where: c.followee_id == ^user_id, select: %{count: count()})
    |> since(read_at)
  end

  defp count_endorsements(user_id, read_at) do
    from(e in UserTagEndorsement,
      join: ut in assoc(e, :user_tag),
      where: ut.user_id == ^user_id and e.user_id != ^user_id,
      select: %{count: count()}
    )
    |> since(read_at)
  end

  defp count_connections(user_id, read_at) do
    query =
      from(c in Connection,
        join: r in Connection,
        on: r.follower_id == c.followee_id and r.followee_id == c.follower_id,
        where: c.followee_id == ^user_id,
        select: %{count: count()}
      )

    if read_at do
      # The mutuality event happens at the later of the two follows.
      where(
        query,
        [c, r],
        fragment("GREATEST(?, ?) > ?", c.inserted_at, r.inserted_at, ^read_at)
      )
    else
      query
    end
  end

  defp since(query, nil), do: query
  defp since(query, read_at), do: where(query, [event], event.inserted_at > ^read_at)

  defp actor_param(%User{} = user), do: Phoenix.Param.to_param(user)
  defp actor_param(_), do: nil

  defp actor_avatar(%User{} = user), do: Vutuv.Avatar.display_url(user, :thumb)
  defp actor_avatar(_), do: nil

  defp display_name(%{first_name: first, last_name: last}) do
    [first, last]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> "Someone"
      name -> name
    end
  end

  defp display_name(_), do: "Someone"
end
