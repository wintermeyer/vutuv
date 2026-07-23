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
  (`follows` — a one-way follow is a "follower" event, a mutual follow a
  "connection"/vernetzt one —, `user_tag_endorsements`, `post_replies`,
  `post_likes`, and the announced CV rows behind
  `Vutuv.Profiles.CvUpdates`) instead of being
  persisted per notification — which makes it automatically retroactive. The only stored
  state is `users.notifications_read_at`, the read marker behind the unread
  badge; `mark_notifications_read/1` bumps it and broadcasts. Older events are
  reached via `notifications_page/2`, a timestamp-cursor pagination that backs
  the "Load more" button.
  """
  import Ecto.Query
  require Logger

  alias Vutuv.Accounts.HandleChangeNotification
  alias Vutuv.Accounts.User
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Organizations.Organization
  alias Vutuv.Organizations.OrganizationRole
  alias Vutuv.Posts.PostLike
  alias Vutuv.Posts.PostReply
  alias Vutuv.Profiles.CvUpdates
  alias Vutuv.Repo
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

  # One round trip instead of nine: every event source contributes its MAX as
  # a UNION ALL arm and the outer query takes the greatest. The arms mirror
  # the per-kind event queries below; keep them in sync.
  defp latest_event_at(user_id) do
    follower_max =
      from(c in Follow, where: c.followee_id == ^user_id, select: %{ts: max(c.inserted_at)})

    endorsement_max =
      from(e in UserTagEndorsement,
        join: ut in assoc(e, :user_tag),
        where: ut.user_id == ^user_id and e.user_id != ^user_id,
        select: %{ts: max(e.inserted_at)}
      )

    # "Became vernetzt" events are derived from mutual follows: the pair's
    # timestamp is the later of the two follow times (GREATEST), matching
    # connection_items/3 below.
    connection_max =
      from(out in Follow,
        join: back in Follow,
        on: back.follower_id == out.followee_id and back.followee_id == out.follower_id,
        where: out.follower_id == ^user_id,
        select: %{ts: max(fragment("GREATEST(?, ?)", out.inserted_at, back.inserted_at))}
      )

    reply_max =
      from(r in PostReply,
        join: reply in assoc(r, :post),
        where: r.parent_author_id == ^user_id and reply.user_id != ^user_id,
        select: %{ts: max(r.inserted_at)}
      )

    like_max =
      from(l in PostLike,
        join: p in assoc(l, :post),
        where: p.user_id == ^user_id and l.user_id != ^user_id,
        select: %{ts: max(l.inserted_at)}
      )

    moderation_max =
      Vutuv.Moderation.owner_notified_cases_query(user_id)
      |> select([c], %{ts: max(c.inserted_at)})

    image_rejected_max =
      ImageScans.rejected_scans_query(user_id)
      |> select([s], %{ts: max(s.inserted_at)})

    severances = Vutuv.Moderation.reporter_severances_query(user_id)
    severance_max = select(severances, [s], %{ts: max(s.inserted_at)})
    severance_restore_max = select(severances, [s], %{ts: max(s.restored_at)})

    # Mirror count_organization_roles/2 (issue #930): without this arm the read
    # marker ignores an org-role grant, so its unread badge never clears.
    organization_role_max =
      from(r in OrganizationRole,
        where: r.user_id == ^user_id and r.granted_by_user_id != ^user_id,
        select: %{ts: max(r.inserted_at)}
      )

    handle_change_max =
      from(n in HandleChangeNotification,
        where: n.recipient_id == ^user_id,
        select: %{ts: max(n.inserted_at)}
      )

    # New CV entries of the people this member follows (issue #980). Without
    # this arm the marker ignores them, so their unread badge never clears.
    cv_update_max =
      user_id
      |> CvUpdates.feed_query()
      |> select([e], %{ts: max(e.inserted_at)})

    # The "this is your username" welcome note (see username_items/3). Without
    # this arm the read marker would ignore it, and a kind the marker ignores
    # never clears its badge — the same bug every other kind once had.
    username_max =
      from(u in User,
        where: u.id == ^user_id,
        select: %{ts: max(u.welcome_notified_at)}
      )

    union =
      follower_max
      |> union_all(^endorsement_max)
      |> union_all(^connection_max)
      |> union_all(^reply_max)
      |> union_all(^like_max)
      |> union_all(^moderation_max)
      |> union_all(^image_rejected_max)
      |> union_all(^severance_max)
      |> union_all(^severance_restore_max)
      |> union_all(^organization_role_max)
      |> union_all(^handle_change_max)
      |> union_all(^cv_update_max)
      |> union_all(^username_max)

    from(t in subquery(union), select: max(t.ts))
    |> Repo.one()
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
    Vutuv.Webhooks.emit(followee_id, "follower.created", %{
      "follower" => actor_param(follower)
    })

    notify(
      followee_id,
      Map.merge(actor_fields(follower), %{
        kind: "follower",
        text: "started following you.",
        at: DateTime.utc_now()
      })
    )

    maybe_email(followee_id, follower, :email_on_follower?, fn email, user ->
      Emailer.new_follower_email(email, user, follower)
    end)
  end

  @doc """
  Convenience: a "made you an admin of <organization>" notification for the member
  who was granted an organization role (issue #930). The derived feed already picks up
  the `organization_roles` row; this live push updates the open session's badge and
  toast at grant time. The actor is the granting member, rendered as a linked
  `@handle`.
  """
  def notify_organization_role(user_id, granter, %Organization{} = organization, role) do
    notify(
      user_id,
      Map.merge(actor_fields(granter), %{
        kind: "organization_role",
        role: role,
        organization_name: organization.name,
        organization_slug: organization.slug,
        at: DateTime.utc_now()
      })
    )
  end

  @doc """
  Live push for one persisted `HandleChangeNotification`: tells the affected
  post author, in their open session, that `@old_handle` renamed to
  `@new_handle` and which of their posts were rewritten. The durable row is the
  feed's source of truth (`handle_change_items/3`); this only lights up the
  badge and toast at rename time. `actor` is the renamed member (the new
  handle), so the row links to the current profile.
  """
  def notify_handle_change(%HandleChangeNotification{} = notification, %User{} = actor) do
    notify(
      notification.recipient_id,
      Map.merge(actor_fields(actor), %{
        kind: "handle_change",
        old_handle: notification.old_handle,
        new_handle: notification.new_handle,
        post_ids: notification.post_ids,
        at: notification.inserted_at
      })
    )
  end

  @doc """
  Live push for a new CV entry one of the recipient's followees just added and
  chose to announce (issue #980). `payload` is
  `Vutuv.Profiles.CvUpdates.group_payload/2` — the author's whole current
  sitting, under that sitting's own id, exactly what the derived feed renders.
  Because the id is the derived one, a second entry less than the grouping gap
  later **updates** the row an open page already shows instead of stacking
  another.
  In-app only: this kind never mails.
  """
  def notify_cv_update(recipient_id, %User{} = author, %{} = payload) do
    notify(recipient_id, Map.merge(actor_fields(author), Map.put(payload, :kind, "cv_update")))
  end

  @doc ~S(Convenience: an "endorsed you for <tag>" notification for the tag's owner.)
  def notify_endorsement(owner_id, endorser, tag_name) do
    Vutuv.Webhooks.emit(owner_id, "endorsement.created", %{
      "endorser" => actor_param(endorser),
      "tag" => tag_name
    })

    notify(
      owner_id,
      Map.merge(actor_fields(endorser), %{
        kind: "endorsement",
        tag: tag_name,
        text: "endorsed you for #{tag_name}.",
        at: DateTime.utc_now()
      })
    )

    maybe_email(owner_id, endorser, :email_on_endorsement?, fn email, user ->
      Emailer.endorsement_email(email, user, endorser, tag_name)
    end)
  end

  @doc ~S"""
  Convenience: a "replied to your post" notification for the parent post's
  author. `post_id` is the parent post, so the notification can link to the
  thread the reply landed in.
  """
  def notify_reply(parent_author_id, replier, parent_post_id \\ nil, reply_post_id \\ nil) do
    Vutuv.Webhooks.emit(parent_author_id, "post.replied", %{
      "by" => actor_param(replier),
      "post_id" => parent_post_id
    })

    notify(
      parent_author_id,
      Map.merge(actor_fields(replier), %{
        kind: "reply",
        text: "replied to your post.",
        # The recipient's own post that was replied to (what the row links to)…
        post_id: parent_post_id,
        # …and the reply itself, so the row can quote both.
        reply_post_id: reply_post_id,
        at: DateTime.utc_now()
      })
    )
  end

  @doc ~S(Convenience: a "liked your post" notification for the post's author.)
  def notify_like(author_id, liker, post_id) do
    Vutuv.Webhooks.emit(author_id, "post.liked", %{
      "by" => actor_param(liker),
      "post_id" => post_id
    })

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
  An "is now connected with you" notification — fired when a follow-back
  completes a mutual follow, so the pair is now vernetzt (connected). A
  follow-back is also a new follow, so it carries the same `connection.created`
  webhook and honors the recipient's `:email_on_follower?` opt-in (reusing the
  new-follower email); only the in-app text/kind announces the connection
  milestone. The derived feed reuses the `"connection"` kind for mutual pairs.
  """
  def notify_connection(user_id, other) do
    Vutuv.Webhooks.emit(user_id, "connection.created", %{
      "with" => actor_param(other)
    })

    notify(
      user_id,
      Map.merge(actor_fields(other), %{
        kind: "connection",
        text: "is now connected with you.",
        at: DateTime.utc_now()
      })
    )

    maybe_email(user_id, other, :email_on_follower?, fn email, user ->
      Emailer.new_follower_email(email, user, other)
    end)
  end

  @doc """
  Tells a reporter that their report severed ("severed") or a rejected case
  restored ("restored") the relationship to the reported member. The actor
  fields carry the *reported* member so the feed entry can name and link
  @their_handle. The durable counterpart is derived from the severance rows
  (see `report_protection_items/3`).
  """
  def notify_report_protection(reporter_id, reported_user, status) do
    notify(
      reporter_id,
      Map.merge(actor_fields(reported_user), %{
        kind: "report_protection",
        status: status,
        at: DateTime.utc_now()
      })
    )
  end

  # Opt-in activity email. The in-app notification above always fires; this only
  # adds the email copy when the recipient switched the matching preference on
  # (all default off, set on the notifications settings page). Confirmed
  # accounts only (the dormant legacy members are email_confirmed? false), never
  # the actor themselves, and a delivery failure must never break the social
  # action that triggered it. `build` turns the looked-up address + recipient
  # into the `%Swoosh.Email{}` to deliver. Sent inline: these are low-frequency
  # events and the preference defaults off, so most actions never reach here.
  defp maybe_email(recipient_id, actor, field, build) when is_map(actor) do
    actor_id = Map.get(actor, :id)

    if recipient_id && recipient_id != actor_id do
      # The whole lookup + send is best-effort: any failure (a bad id, an SMTP
      # error) is logged and swallowed so it never breaks the social action that
      # already fired its in-app notification above.
      try do
        with %User{email_confirmed?: true} = user <- Vutuv.Accounts.get_user(recipient_id),
             true <- Map.get(user, field),
             email when is_binary(email) <- Vutuv.Accounts.first_email_value(user) do
          email |> build.(user) |> Emailer.deliver()
        end
      rescue
        e -> Logger.error("activity email (#{field}) failed: #{Exception.message(e)}")
      end
    end

    :ok
  end

  defp maybe_email(_recipient_id, _actor, _field, _build), do: :ok

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

  `page:` (a 1-based page number) switches to numbered **offset** pagination
  instead — the same merged feed walked by page rather than by cursor, which
  is what /notifications renders (a page you can link to and jump around in);
  `next_cursor` is then always nil. Pass one or the other, not both.

  `kinds:` (a list of kind strings) restricts the feed to those event kinds -
  only the matching source queries run, so a filtered page paginates exactly
  like the full feed. Backs the filter tabs on /notifications; omitting it
  keeps the whole feed (the API and the shell badge pass no kinds).
  """
  def notifications_page(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    kinds = Keyword.get(opts, :kinds)
    page = Keyword.get(opts, :page)

    sources =
      for {kind, source} <- kind_sources(user_id), kinds == nil or kind in kinds, do: source

    if page,
      do: Vutuv.FeedPage.paginate_offset(sources, limit, (max(page, 1) - 1) * limit),
      else: Vutuv.FeedPage.paginate(sources, limit, Keyword.get(opts, :cursor))
  end

  # Every feed source keyed by the kind string its items carry, so `kinds:`
  # can pick the subset to query. `report_protection` covers both the severed
  # and the restored entry (one source emits them together).
  defp kind_sources(user_id) do
    [
      {"follower", &follower_items(user_id, &1, &2)},
      {"endorsement", &endorsement_items(user_id, &1, &2)},
      {"connection", &connection_items(user_id, &1, &2)},
      {"reply", &reply_items(user_id, &1, &2)},
      {"like", &like_items(user_id, &1, &2)},
      {"organization_role", &organization_role_items(user_id, &1, &2)},
      {"moderation", &moderation_items(user_id, &1, &2)},
      {"image_rejected", &image_rejected_items(user_id, &1, &2)},
      {"report_protection", &report_protection_items(user_id, &1, &2)},
      {"handle_change", &handle_change_items(user_id, &1, &2)},
      {"cv_update", &cv_update_items(user_id, &1, &2)},
      {"username", &username_items(user_id, &1, &2)}
    ]
  end

  @doc """
  How much happened per social kind since `since`, in one round trip:
  `%{followers:, connections:, likes:, replies:, endorsements:}`. Backs the
  "Last 30 days" card on /notifications; the rare operational kinds
  (moderation, handle changes, ...) are deliberately not in the glanceable
  summary.
  """
  def activity_summary(user_id, since) do
    Repo.one(
      from(s in subquery(count_followers(user_id, since)),
        select: %{
          followers: s.count,
          connections: subquery(count_connections(user_id, since)),
          likes: subquery(count_likes(user_id, since)),
          replies: subquery(count_replies(user_id, since)),
          endorsements: subquery(count_endorsements(user_id, since))
        }
      )
    )
  end

  @doc """
  The size of the derived feed, read marker ignored. Backs the numbered pager
  under /notifications. Zero for a logged-out visitor.

  `kinds` (a list of kind strings, `nil` = every source) restricts the count
  the same way `notifications_page/2`'s `kinds:` restricts the feed, so a
  filtered tab's page count matches the rows it pages through.
  """
  def notifications_count(user_id, kinds \\ nil)
  def notifications_count(nil, _kinds), do: 0

  def notifications_count(user_id, kinds), do: total_count(user_id, nil, kinds)

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
  # notifications_count/2 needs no marker and so runs in 1 query. The
  # strict `> read_at` unread filter and the GREATEST-anchored mutuality
  # timestamp are unchanged — only the round trips collapse.
  #
  # `kinds` picks the subset to count, mirroring `kind_sources/1`; the sum is
  # built with dynamics so the filtered case stays one query too.
  defp total_count(user_id, read_at, kinds \\ nil) do
    counts =
      for {kind, count} <- kind_counts(user_id, read_at),
          kinds == nil or kind in kinds,
          do: count

    case counts do
      [] ->
        0

      [first | rest] ->
        sum =
          Enum.reduce(rest, dynamic([s], s.count), fn count, acc ->
            dynamic(^acc + subquery(count))
          end)

        Repo.one(from(s in subquery(first), select: ^sum))
    end
  end

  # Every count query keyed by the kind string of the source it counts — the
  # count-side twin of `kind_sources/1`, so a `kinds:` filter narrows the feed
  # and its total the same way. `report_protection` is two queries (severed and
  # restored), matching the one source that emits both.
  defp kind_counts(user_id, read_at) do
    [
      {"follower", count_followers(user_id, read_at)},
      {"endorsement", count_endorsements(user_id, read_at)},
      {"connection", count_connections(user_id, read_at)},
      {"reply", count_replies(user_id, read_at)},
      {"like", count_likes(user_id, read_at)},
      {"organization_role", count_organization_roles(user_id, read_at)},
      {"cv_update", count_cv_updates(user_id, read_at)},
      {"moderation", count_moderation(user_id, read_at)},
      {"image_rejected", count_image_rejections(user_id, read_at)},
      {"report_protection", count_severances(user_id, read_at)},
      {"report_protection", count_severance_restores(user_id, read_at)},
      {"handle_change", count_handle_changes(user_id, read_at)},
      {"username", count_username(user_id, read_at)}
    ]
  end

  defp follower_items(user_id, limit, cursor) do
    from(c in Follow,
      where: c.followee_id == ^user_id,
      join: f in assoc(c, :follower),
      order_by: [desc: c.inserted_at, desc: c.id],
      limit: ^limit,
      select: {c.id, c.inserted_at, struct(f, ^User.listing_fields())}
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
      select: {e.id, e.inserted_at, struct(endorser, ^User.listing_fields()), t.name}
    )
    |> at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, endorser, tag_name} ->
      "endorsement-#{id}"
      |> actor_item("endorsement", at, endorser)
      |> Map.put(:tag, tag_name)
    end)
  end

  # "Became vernetzt" events, derived from mutual follows (the user follows
  # someone who follows them back). Timestamped at the later of the two follow
  # times (`GREATEST`), so the item lands in the feed when the pair actually
  # became mutual; the later follow's id is the stable item id. There is no
  # separate connection record any more, so a one-way follow simply does not
  # surface here (it is a `follower_items/3` entry instead).
  defp connection_items(user_id, limit, cursor) do
    query =
      from(out in Follow,
        join: back in Follow,
        on: back.follower_id == out.followee_id and back.followee_id == out.follower_id,
        join: u in User,
        on: u.id == out.followee_id,
        where: out.follower_id == ^user_id,
        order_by: [
          desc: fragment("GREATEST(?, ?)", out.inserted_at, back.inserted_at),
          desc: fragment("GREATEST(?, ?)", out.id, back.id)
        ],
        limit: ^limit,
        select: %{
          id: type(fragment("GREATEST(?, ?)", out.id, back.id), Vutuv.UUIDv7),
          at:
            type(fragment("GREATEST(?, ?)", out.inserted_at, back.inserted_at), :naive_datetime),
          friend: struct(u, ^User.listing_fields())
        }
      )

    query =
      if cursor,
        do:
          where(
            query,
            [out, back],
            fragment("GREATEST(?, ?)", out.inserted_at, back.inserted_at) <= ^cursor.at
          ),
        else: query

    query
    |> Repo.all()
    |> Enum.map(fn %{id: id, at: at, friend: friend} ->
      actor_item("connection-#{id}", "connection", at, friend)
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
      select:
        {r.id, r.inserted_at, struct(replier, ^User.listing_fields()), r.parent_post_id,
         r.post_id}
    )
    |> at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, replier, parent_post_id, reply_post_id} ->
      "reply-#{id}"
      |> actor_item("reply", at, replier)
      # The parent (the recipient's own post the row links to) and the reply
      # itself, so the row can quote both.
      |> Map.put(:post_id, parent_post_id)
      |> Map.put(:reply_post_id, reply_post_id)
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
      select: {l.id, l.inserted_at, struct(liker, ^User.listing_fields()), p.id}
    )
    |> at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, liker, post_id} ->
      "like-#{id}"
      |> actor_item("like", at, liker)
      |> Map.put(:post_id, post_id)
    end)
  end

  # Organization-role grants (issue #930): a member made owner/admin/recruiter of a
  # verified organization page. A self-grant (the claim wizard makes the creator
  # owner) is excluded — the `granted_by != user` filter drops it (and a nil
  # granter, keeping the count query below in lock-step).
  defp organization_role_items(user_id, limit, cursor) do
    from(r in OrganizationRole,
      join: c in Organization,
      on: c.id == r.organization_id,
      join: granter in User,
      on: granter.id == r.granted_by_user_id,
      where: r.user_id == ^user_id and r.granted_by_user_id != ^user_id,
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^limit,
      select:
        {r.id, r.inserted_at, struct(granter, ^User.listing_fields()), r.role, c.name, c.slug}
    )
    |> at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, granter, role, name, slug} ->
      "organization-role-#{id}"
      |> actor_item("organization_role", at, granter)
      |> Map.merge(%{role: role, organization_name: name, organization_slug: slug})
    end)
  end

  # Moderation cases about the user's own content. Which cases the owner was
  # actually told about is Moderation's rule, not ours — the query comes from
  # there so this feed cannot drift from the notify behavior.
  defp moderation_items(user_id, limit, cursor) do
    Vutuv.Moderation.owner_notified_cases_query(user_id)
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> limit(^limit)
    |> select([c], {c.id, c.inserted_at, c.status})
    |> at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, status} ->
      %{
        id: "moderation-#{id}",
        kind: "moderation",
        at: at,
        case_id: id,
        status: status
      }
    end)
  end

  # An image the AI safety scan rejected and deleted (avatar, cover, a post /
  # job-posting / organization image). Derived from the rejected scan rows —
  # the audit record of the deletion — so the entry survives the live push
  # and predates nothing: rejection only exists since the feature does.
  defp image_rejected_items(user_id, limit, cursor) do
    ImageScans.rejected_scans_query(user_id)
    |> order_by([s], desc: s.inserted_at, desc: s.id)
    |> limit(^limit)
    |> select([s], {s.id, s.inserted_at, s.kind, s.category})
    |> at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, kind, category} ->
      %{
        id: "image-rejected-#{id}",
        kind: "image_rejected",
        at: at,
        image_kind: kind,
        category: category
      }
    end)
  end

  # The reporter-protection entries: one when a report severed the
  # relationship to the reported member, a second when a rejected case
  # restored it. Both derive from the same severance row (Moderation owns the
  # rule), timestamped by inserted_at / restored_at respectively. The actor
  # is the *reported* member, so the entry links @their_handle.
  defp report_protection_items(user_id, limit, cursor) do
    severed =
      Vutuv.Moderation.reporter_severances_query(user_id)
      |> join(:inner, [s], u in User, on: u.id == s.owner_id)
      |> order_by([s], desc: s.inserted_at, desc: s.id)
      |> limit(^limit)
      |> at_or_before(cursor)
      |> select([s, u], {s.id, s.inserted_at, struct(u, ^User.listing_fields())})
      |> Repo.all()
      |> Enum.map(fn {id, at, reported} ->
        protection_item("report-protection-#{id}", "severed", at, reported)
      end)

    restored =
      Vutuv.Moderation.reporter_severances_query(user_id)
      |> where([s], not is_nil(s.restored_at))
      |> join(:inner, [s], u in User, on: u.id == s.owner_id)
      |> order_by([s], desc: s.restored_at, desc: s.id)
      |> limit(^limit)
      |> restored_at_or_before(cursor)
      |> select([s, u], {s.id, s.restored_at, struct(u, ^User.listing_fields())})
      |> Repo.all()
      |> Enum.map(fn {id, at, reported} ->
        protection_item("report-protection-restored-#{id}", "restored", at, reported)
      end)

    severed ++ restored
  end

  # "@old renamed to @new" entries for a post author whose posts were rewritten
  # (issue: handle-change propagation). Derived from the durable
  # `handle_change_notifications` rows — the only feed kind that needs its own
  # table, because the old handle is a point-in-time fact the current-state
  # sources can't reconstruct. `post_ids` carries the affected posts so the
  # LiveView can link them (count + last 5). The actor is the renamed member.
  defp handle_change_items(user_id, limit, cursor) do
    from(n in HandleChangeNotification,
      join: actor in assoc(n, :actor),
      where: n.recipient_id == ^user_id,
      order_by: [desc: n.inserted_at, desc: n.id],
      limit: ^limit,
      select:
        {n.id, n.inserted_at, struct(actor, ^User.listing_fields()), n.old_handle, n.new_handle,
         n.post_ids}
    )
    |> at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, actor, old_handle, new_handle, post_ids} ->
      "handle-change-#{id}"
      |> actor_item("handle_change", at, actor)
      |> Map.merge(%{old_handle: old_handle, new_handle: new_handle, post_ids: post_ids})
    end)
  end

  # "Added a new position to their CV" entries (issue #980): the announced CV
  # rows of the people this member follows, **grouped per sitting** (entries
  # less than three hours apart) — somebody filling in five roles in one go is
  # one piece of news, not five. Derived straight from the CV tables through the one rule in
  # `Vutuv.Profiles.CvUpdates`, so deleting an entry drops it from its group
  # and renaming the job renames it. The actor is the author; a single-entry
  # group links to that entry's page, a bigger one to the profile.
  defp cv_update_items(user_id, limit, cursor) do
    user_id
    |> CvUpdates.page(limit, cursor)
    |> Enum.map(fn %{author: author} = group ->
      group
      |> Map.delete(:author)
      |> Map.merge(actor_fields(author))
      |> Map.put(:kind, "cv_update")
    end)
  end

  defp protection_item(id, status, at, reported) do
    id
    |> actor_item("report_protection", at, reported)
    |> Map.put(:status, status)
  end

  defp restored_at_or_before(query, nil), do: query
  defp restored_at_or_before(query, %{at: at}), do: where(query, [s], s.restored_at <= ^at)

  # "Your username is @handle" — the one welcome note a member gets when their
  # very first login PIN is accepted. vutuv generates the handle from their
  # name (Vutuv.Handles), so nothing before that moment ever named it; this
  # entry does, and links to where they can change it.
  #
  # Derived straight from the member's own users row — no notification table,
  # no push, and deliberately **no email**: it is an in-app note, not another
  # message on top of the PIN mail they just received. `welcome_notified_at`
  # (stamped by Accounts.activate_user/1) is both the gate and the timestamp,
  # so accounts that predate the feature keep a clean feed instead of being
  # handed a welcome years after the fact.
  defp username_items(user_id, limit, cursor) do
    from(u in User,
      where: u.id == ^user_id and not is_nil(u.welcome_notified_at),
      limit: ^limit,
      select: {u.id, u.welcome_notified_at, u.username}
    )
    |> at_or_before_welcome(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, username} ->
      %{id: "username-#{id}", kind: "username", at: at, username: username}
    end)
  end

  # The users row is keyed on welcome_notified_at, not inserted_at, so it needs
  # its own cursor clause (at_or_before/2 filters on inserted_at).
  defp at_or_before_welcome(query, nil), do: query

  defp at_or_before_welcome(query, %{at: at}),
    do: where(query, [u], u.welcome_notified_at <= ^at)

  defp at_or_before(query, nil), do: query
  defp at_or_before(query, %{at: at}), do: where(query, [event], event.inserted_at <= ^at)

  defp actor_item(id, kind, at, actor) do
    Map.merge(actor_fields(actor), %{id: id, kind: kind, at: at})
  end

  # The actor fields (id / name / route param / avatar) that the live `notify_*`
  # payloads and the derived feed items must carry identically. Both sides merge
  # their own kind/text/at (and :tag for endorsements) onto this, so the shapes
  # stay in lock-step. Accepts a bare map too: the activity tests pass plain
  # maps as actors, where only the name is derivable. `actor_id` keys the
  # online-presence dot on the actor's avatar (nil for non-User actors).
  defp actor_fields(actor) do
    %{
      actor_id: actor_id(actor),
      actor_name: display_name(actor),
      actor_param: actor_param(actor),
      actor_avatar: actor_avatar(actor)
    }
  end

  defp actor_id(%User{id: id}), do: id
  defp actor_id(_), do: nil

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

  # Mutual follows (vernetzt), counted from the same self-join as
  # connection_items/3; the "became mutual" time is the later of the two
  # follows (GREATEST), so the unread filter matches the items.
  defp count_connections(user_id, read_at) do
    query =
      from(out in Follow,
        join: back in Follow,
        on: back.follower_id == out.followee_id and back.followee_id == out.follower_id,
        where: out.follower_id == ^user_id,
        select: %{count: count()}
      )

    if read_at do
      where(
        query,
        [out, back],
        fragment("GREATEST(?, ?)", out.inserted_at, back.inserted_at) > ^read_at
      )
    else
      query
    end
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

  defp count_organization_roles(user_id, read_at) do
    from(r in OrganizationRole,
      where: r.user_id == ^user_id and r.granted_by_user_id != ^user_id,
      select: %{count: count()}
    )
    |> since(read_at)
  end

  # Counts CV update **sittings**, not rows: the badge must match what the page
  # renders, so a five-entry burst in one sitting is one unread item. The
  # read-marker filter lives inside the grouped query (a HAVING on the
  # sitting's newest entry), hence no `since/2` here.
  defp count_cv_updates(user_id, read_at) do
    from(group in subquery(CvUpdates.count_query(user_id, read_at)), select: %{count: count()})
  end

  defp count_moderation(user_id, read_at) do
    Vutuv.Moderation.owner_notified_cases_query(user_id)
    |> select([c], %{count: count()})
    |> since(read_at)
  end

  defp count_image_rejections(user_id, read_at) do
    ImageScans.rejected_scans_query(user_id)
    |> select([s], %{count: count()})
    |> since(read_at)
  end

  defp count_severances(user_id, read_at) do
    Vutuv.Moderation.reporter_severances_query(user_id)
    |> select([s], %{count: count()})
    |> since(read_at)
  end

  defp count_severance_restores(user_id, read_at) do
    query =
      Vutuv.Moderation.reporter_severances_query(user_id)
      |> where([s], not is_nil(s.restored_at))
      |> select([s], %{count: count()})

    if read_at, do: where(query, [s], s.restored_at > ^read_at), else: query
  end

  defp count_handle_changes(user_id, read_at) do
    from(n in HandleChangeNotification,
      where: n.recipient_id == ^user_id,
      select: %{count: count()}
    )
    |> since(read_at)
  end

  defp count_username(user_id, read_at) do
    query =
      from(u in User,
        where: u.id == ^user_id and not is_nil(u.welcome_notified_at),
        select: %{count: count()}
      )

    if read_at, do: where(query, [u], u.welcome_notified_at > ^read_at), else: query
  end

  defp since(query, nil), do: query
  defp since(query, read_at), do: where(query, [event], event.inserted_at > ^read_at)

  defp actor_param(%User{} = user), do: Phoenix.Param.to_param(user)
  defp actor_param(_), do: nil

  # nil (not the default-placeholder URL) when the actor has no picture, so
  # the notifications page renders its colored kind glyph instead of a grey
  # anonymous image.
  defp actor_avatar(%User{avatar: nil}), do: nil
  # An avatar in AI-moderation limbo renders like none (the kind glyph), not
  # as the grey placeholder display_url would fall back to.
  defp actor_avatar(%User{avatar_moderation: "pending"}), do: nil
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
