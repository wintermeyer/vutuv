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
  (`follows`, `connections` — accepted ones and pending incoming requests —,
  `user_tag_endorsements`, `post_replies`, `post_likes`) instead of being
  persisted per notification — which makes it automatically retroactive. The only stored
  state is `users.notifications_read_at`, the read marker behind the unread
  badge; `mark_notifications_read/1` bumps it and broadcasts. Older events are
  reached via `notifications_page/2`, a timestamp-cursor pagination that backs
  the "Load more" button.
  """
  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Posts.PostLike
  alias Vutuv.Posts.PostReply
  alias Vutuv.Repo
  alias Vutuv.Social.Connection
  alias Vutuv.Social.Follow
  alias Vutuv.Tags.UserTagEndorsement

  @pubsub Vutuv.PubSub
  @default_limit 50

  defp topic(user_id), do: "user:#{user_id}"

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
      from(c in Follow, where: c.followee_id == ^user_id, select: max(c.inserted_at))
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
        where: c.status == "accepted" and (c.user_a_id == ^user_id or c.user_b_id == ^user_id),
        select: max(c.status_changed_at)
      )
      |> Repo.one()

    request_max =
      from(c in Connection,
        where:
          c.status == "pending" and (c.user_a_id == ^user_id or c.user_b_id == ^user_id) and
            c.requested_by_id != ^user_id,
        select: max(c.inserted_at)
      )
      |> Repo.one()

    reply_max =
      from(r in PostReply,
        join: reply in assoc(r, :post),
        where: r.parent_author_id == ^user_id and reply.user_id != ^user_id,
        select: max(r.inserted_at)
      )
      |> Repo.one()

    like_max =
      from(l in PostLike,
        join: p in assoc(l, :post),
        where: p.user_id == ^user_id and l.user_id != ^user_id,
        select: max(l.inserted_at)
      )
      |> Repo.one()

    [follower_max, endorsement_max, connection_max, request_max, reply_max, like_max]
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

  @doc ~S"""
  Convenience: a "replied to your post" notification for the parent post's
  author. `post_id` is the parent post, so the notification can link to the
  thread the reply landed in.
  """
  def notify_reply(parent_author_id, replier, post_id \\ nil) do
    notify(
      parent_author_id,
      Map.merge(actor_fields(replier), %{
        kind: "reply",
        text: "replied to your post.",
        post_id: post_id,
        at: DateTime.utc_now()
      })
    )
  end

  @doc ~S(Convenience: a "liked your post" notification for the post's author.)
  def notify_like(author_id, liker, post_id) do
    notify(
      author_id,
      Map.merge(actor_fields(liker), %{
        kind: "like",
        text: "liked your post.",
        post_id: post_id,
        at: DateTime.utc_now()
      })
    )
  end

  @doc ~S"""
  An "is now connected with you" notification — the `"connection"` kind the
  derived feed also uses for accepted connections. The live accept path pushes
  `notify_connection_accepted/2` to the requester instead; this stays for
  completeness and the feed's shared kind vocabulary.
  """
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

  @doc ~S(Convenience: a "wants to connect with you" notification for the request recipient.)
  def notify_connection_request(recipient_id, requester) do
    notify(
      recipient_id,
      Map.merge(actor_fields(requester), %{
        kind: "connection_request",
        text: "wants to connect with you.",
        at: DateTime.utc_now()
      })
    )
  end

  @doc ~S(Convenience: an "accepted your connection request" notification for the requester.)
  def notify_connection_accepted(requester_id, accepter) do
    notify(
      requester_id,
      Map.merge(actor_fields(accepter), %{
        kind: "connection_accepted",
        text: "accepted your connection request.",
        at: DateTime.utc_now()
      })
    )
  end

  ## Derived notifications feed

  @doc """
  One page of the user's notification feed (newest first) plus pagination
  state for a "Load more" UI: `%{entries: [...], more?: boolean,
  next_cursor: cursor | nil}`. Pass the returned cursor back as `cursor:` to
  get the next-older page.

  The feed is derived straight from its source tables — followers
  (`follows`), endorsements (`user_tag_endorsements`, with the tag's name),
  connections (accepted `connections` rows, timestamped at acceptance) and
  replies (`post_replies`, minus self-replies) — so it includes events from
  before this feature existed.
  Items mirror the live `notify_*` payload shape; ids are
  `"<kind>-<row id>"` strings, which keeps them out of the `"live-"` id
  namespace the LiveView uses for pushed events.

  The cursor (and the merge across the sources) is the shared
  `Vutuv.FeedPage` scheme. Treat it as opaque.
  """
  def notifications_page(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    cursor = Keyword.get(opts, :cursor)

    Vutuv.FeedPage.paginate(
      [
        &follower_items(user_id, &1, &2),
        &endorsement_items(user_id, &1, &2),
        &connection_items(user_id, &1, &2),
        &connection_request_items(user_id, &1, &2),
        &reply_items(user_id, &1, &2),
        &like_items(user_id, &1, &2)
      ],
      limit,
      cursor
    )
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

  # The feed sources are counted in a single round trip: each count is a
  # scalar subquery, summed in one SELECT. unread_notification_count/1 still
  # needs one prior read for the marker, so it ends up at 2 queries;
  # notifications_count/1 needs no marker and so runs in 1 query. The
  # strict `> read_at` unread filter and the GREATEST-anchored mutuality
  # timestamp are unchanged — only the round trips collapse.
  defp total_count(user_id, read_at) do
    Repo.one(
      from(s in subquery(count_followers(user_id, read_at)),
        select:
          s.count + subquery(count_endorsements(user_id, read_at)) +
            subquery(count_connections(user_id, read_at)) +
            subquery(count_connection_requests(user_id, read_at)) +
            subquery(count_replies(user_id, read_at)) +
            subquery(count_likes(user_id, read_at))
      )
    )
  end

  defp follower_items(user_id, limit, cursor) do
    from(c in Follow,
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

  # Accepted connections where the user is a party, timestamped at acceptance
  # (`status_changed_at`). The CASE join resolves the *other* party so the feed
  # item names the friend, not the user themselves. The requester reads the
  # event as "accepted your connection request"; the acceptor as the plain
  # "is now connected with you".
  defp connection_items(user_id, limit, cursor) do
    query =
      from(c in Connection,
        where: c.status == "accepted" and (c.user_a_id == ^user_id or c.user_b_id == ^user_id),
        join: u in User,
        on:
          u.id ==
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE ? END",
              c.user_a_id,
              type(^user_id, Vutuv.UUIDv7),
              c.user_b_id,
              c.user_a_id
            ),
        order_by: [desc: c.status_changed_at, desc: c.id],
        limit: ^limit,
        select: {c.id, c.status_changed_at, u, c.requested_by_id}
      )

    query = if cursor, do: where(query, [c], c.status_changed_at <= ^cursor.at), else: query

    query
    |> Repo.all()
    |> Enum.map(fn {id, at, friend, requested_by_id} ->
      kind = if requested_by_id == user_id, do: "connection_accepted", else: "connection"
      actor_item("connection-#{id}", kind, at, friend)
    end)
  end

  # Pending requests waiting on this user's answer. They live in the feed so
  # an offline recipient still discovers them; once answered, the row leaves
  # the pending state and the item disappears (accepted ones re-enter above).
  defp connection_request_items(user_id, limit, cursor) do
    from(c in Connection,
      where:
        c.status == "pending" and (c.user_a_id == ^user_id or c.user_b_id == ^user_id) and
          c.requested_by_id != ^user_id,
      join: u in User,
      on: u.id == c.requested_by_id,
      order_by: [desc: c.inserted_at, desc: c.id],
      limit: ^limit,
      select: {c.id, c.inserted_at, u}
    )
    |> at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, requester} ->
      actor_item("connection_request-#{id}", "connection_request", at, requester)
    end)
  end

  defp reply_items(user_id, limit, cursor) do
    from(r in PostReply,
      join: reply in assoc(r, :post),
      join: replier in assoc(reply, :user),
      # Self-replies (threading your own post) are not news.
      where: r.parent_author_id == ^user_id and reply.user_id != ^user_id,
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^limit,
      select: {r.id, r.inserted_at, replier, r.parent_post_id}
    )
    |> at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, replier, parent_post_id} ->
      "reply-#{id}"
      |> actor_item("reply", at, replier)
      |> Map.put(:post_id, parent_post_id)
    end)
  end

  # Likes on this user's posts, minus self-likes. Carries the liked post's id
  # so the notification can link to it.
  defp like_items(user_id, limit, cursor) do
    from(l in PostLike,
      join: p in assoc(l, :post),
      join: liker in assoc(l, :user),
      where: p.user_id == ^user_id and l.user_id != ^user_id,
      order_by: [desc: l.inserted_at, desc: l.id],
      limit: ^limit,
      select: {l.id, l.inserted_at, liker, p.id}
    )
    |> at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, liker, post_id} ->
      "like-#{id}"
      |> actor_item("like", at, liker)
      |> Map.put(:post_id, post_id)
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
    from(c in Follow, where: c.followee_id == ^user_id, select: %{count: count()})
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
        where: c.status == "accepted" and (c.user_a_id == ^user_id or c.user_b_id == ^user_id),
        select: %{count: count()}
      )

    if read_at do
      where(query, [c], c.status_changed_at > ^read_at)
    else
      query
    end
  end

  defp count_connection_requests(user_id, read_at) do
    from(c in Connection,
      where:
        c.status == "pending" and (c.user_a_id == ^user_id or c.user_b_id == ^user_id) and
          c.requested_by_id != ^user_id,
      select: %{count: count()}
    )
    |> since(read_at)
  end

  defp count_replies(user_id, read_at) do
    from(r in PostReply,
      join: reply in assoc(r, :post),
      where: r.parent_author_id == ^user_id and reply.user_id != ^user_id,
      select: %{count: count()}
    )
    |> since(read_at)
  end

  defp count_likes(user_id, read_at) do
    from(l in PostLike,
      join: p in assoc(l, :post),
      where: p.user_id == ^user_id and l.user_id != ^user_id,
      select: %{count: count()}
    )
    |> since(read_at)
  end

  defp since(query, nil), do: query
  defp since(query, read_at), do: where(query, [event], event.inserted_at > ^read_at)

  defp actor_param(%User{} = user), do: Phoenix.Param.to_param(user)
  defp actor_param(_), do: nil

  # nil (not the default-placeholder URL) when the actor has no picture, so
  # the notifications page renders its colored kind glyph instead of a grey
  # anonymous image.
  defp actor_avatar(%User{avatar: nil}), do: nil
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
