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
  "connection"/vernetzt one —, `user_tag_endorsements`, `post_replies` — a
  reply answering the user's post is a "reply" event, a reply elsewhere in a
  thread the user writes in a "thread" one —, `post_mentions` — a post naming
  the user by `@handle` is a "mention" event —, `post_likes`, and the announced
  CV rows behind `Vutuv.Profiles.CvUpdates`) instead of being
  persisted per notification — which makes it automatically retroactive. Older
  events are reached via `notifications_page/2`, a timestamp-cursor pagination
  that backs the "Load more" button.

  Read state is stored in two places, and they answer different questions:

    * `users.notifications_read_at` is the **marker**: everything up to here
      has been seen. `mark_notifications_read/1` bumps it and broadcasts, which
      is what opening /notifications does.
    * `notification_post_reads` holds the **per-post** exceptions written by
      `mark_post_seen/2`: the member answered, liked, bookmarked or reposted
      that post, so what the feed has to say about it is old news even though
      the marker still sits behind it. Only the unread tally consults them —
      the page keeps listing those events, it just stops calling them new.
    * `notification_dismissals` holds the **per-event** exceptions written by
      `mark_notification_seen/3`: the member clicked the browser notification
      that announced this one event, so it is read and the rest of the bell is
      not. Both the tally and the notifications page consult them, keyed on the
      `event_id/2` pair the feed already gives every item.
  """
  import Ecto.Query
  import Vutuv.Identity.Query, only: [join_party: 3, shown_party: 2]

  alias Vutuv.Accounts.HandleChangeNotification
  alias Vutuv.Accounts.User
  alias Vutuv.Activity.NotificationDismissal
  alias Vutuv.Activity.NotificationPostRead
  alias Vutuv.Engagement
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.Reaction
  alias Vutuv.Identity
  alias Vutuv.MastodonApi.PushDispatcher
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Organizations.Organization
  alias Vutuv.Organizations.OrganizationRole
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostLike
  alias Vutuv.Posts.PostMention
  alias Vutuv.Posts.PostReply
  alias Vutuv.Profiles.CvUpdates
  alias Vutuv.References.Check
  alias Vutuv.Repo
  alias Vutuv.Social.Follow
  alias Vutuv.Tags.UserTagEndorsement
  alias Vutuv.WebPush.Dispatcher, as: WebPushDispatcher

  @pubsub Vutuv.PubSub
  @default_limit 50

  # Struct callers get the one topic grammar (`Vutuv.Identity.topic/1`); the
  # bare-id clause spells the member topic again because most callers hold only
  # an id — `Vutuv.IdentityTest` pins the impl to this exact string.
  defp topic(party) when is_struct(party), do: Identity.topic(party)
  defp topic(user_id), do: "user:#{user_id}"

  def subscribe(nil), do: :ok
  def subscribe(party), do: Phoenix.PubSub.subscribe(@pubsub, topic(party))

  @doc "Broadcast a raw event to a user's topic (no-op for a nil recipient)."
  def broadcast(nil, _event), do: :ok
  def broadcast(party, event), do: Phoenix.PubSub.broadcast(@pubsub, topic(party), event)

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

    # The marker now covers everything the per-event dismissals were holding
    # out of the tally, so they have nothing left to say. Dropping them keeps
    # the table to the handful of exceptions that still matter, rather than a
    # row per browser notification a member ever clicked.
    Repo.delete_all(from(d in NotificationDismissal, where: d.user_id == ^user_id))

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

  # One round trip instead of one per kind: every kind's MAX arm(s) — declared
  # in the `kind_specs/3` registry, so no kind can be forgotten — join a
  # UNION ALL and the outer query takes the greatest. A kind the marker cannot
  # see never clears its badge (the bug behind #980, #930 and v7.200.1), which
  # is why the arms come from the registry and nowhere else.
  defp latest_event_at(user_id) do
    [first | rest] = for spec <- kind_specs(user_id), arm <- spec.max_arms, do: arm

    union = Enum.reduce(rest, first, fn arm, acc -> union_all(acc, ^arm) end)

    from(t in subquery(union), select: max(t.ts))
    |> Repo.one()
  end

  # The read-marker MAX arms, one `%{ts: ...}` query per event family. Each
  # mirrors the filters of its kind's items/count queries below.

  defp follower_max(user_id) do
    from(c in Follow, where: c.followee_id == ^user_id)
    |> join_party(:follower_id, :follower_organization_id)
    |> where([c, u, o], shown_party(u, o))
    |> select([c], %{ts: max(c.inserted_at)})
  end

  defp endorsement_max(user_id) do
    from(e in UserTagEndorsement,
      join: ut in assoc(e, :user_tag),
      where: ut.user_id == ^user_id and e.user_id != ^user_id,
      select: %{ts: max(e.inserted_at)}
    )
  end

  # "Became vernetzt" events are derived from mutual follows: the pair's
  # timestamp is the later of the two follow times (GREATEST), matching
  # connection_items/3 below.
  #
  # This arm deliberately does NOT drop the pairs the member closed themselves,
  # the way the badge tally does (`count_connections/3`). The marker may see
  # more than the tally — that only moves it further forward and empties the
  # badge sooner. The dangerous direction is the other one: a kind the marker
  # cannot see never clears its badge (#980, #930, v7.200.1).
  defp connection_max(user_id) do
    from(out in Follow,
      join: back in Follow,
      on: back.follower_id == out.followee_id and back.followee_id == out.follower_id,
      where: out.follower_id == ^user_id,
      select: %{ts: max(fragment("GREATEST(?, ?)", out.inserted_at, back.inserted_at))}
    )
  end

  defp reply_max(user_id) do
    from(r in PostReply,
      join: reply in assoc(r, :post),
      where: r.parent_author_id == ^user_id and reply.user_id != ^user_id,
      select: %{ts: max(r.inserted_at)}
    )
  end

  defp thread_max(user_id),
    do: select(thread_replies(user_id), [thread_ref: r], %{ts: max(r.inserted_at)})

  defp mention_max(user_id),
    do: select(mention_events(user_id), [mention: m], %{ts: max(m.inserted_at)})

  # Replies and reactions from other networks (issues #1069/#1068).
  # `received_at` is a :utc_datetime, but its column is the same timestamp
  # family as the inserted_at arms, so the union stays type-consistent.
  defp fediverse_reply_max(user_id) do
    user_id
    |> fediverse_reply_events()
    |> select([note: n], %{ts: max(n.received_at)})
  end

  defp fediverse_reaction_max(user_id) do
    user_id
    |> fediverse_reaction_events()
    |> select([note: r], %{ts: max(r.received_at)})
  end

  # No self-like filter needed: a member cannot like their own post
  # (enforced in Posts.like_post/2, issue #1030).
  defp like_max(user_id) do
    from(l in PostLike,
      join: p in assoc(l, :post),
      where: p.user_id == ^user_id,
      select: %{ts: max(l.inserted_at)}
    )
  end

  defp moderation_max(user_id) do
    Vutuv.Moderation.owner_notified_cases_query(user_id)
    |> select([c], %{ts: max(c.inserted_at)})
  end

  defp image_rejected_max(user_id) do
    ImageScans.rejected_scans_query(user_id)
    |> select([s], %{ts: max(s.inserted_at)})
  end

  defp severance_max(user_id) do
    Vutuv.Moderation.reporter_severances_query(user_id)
    |> select([s], %{ts: max(s.inserted_at)})
  end

  # MAX skips NULLs, so rows not (yet) restored contribute nothing here.
  defp severance_restore_max(user_id) do
    Vutuv.Moderation.reporter_severances_query(user_id)
    |> select([s], %{ts: max(s.restored_at)})
  end

  defp organization_role_max(user_id) do
    from(r in OrganizationRole,
      where: r.user_id == ^user_id and r.granted_by_user_id != ^user_id,
      select: %{ts: max(r.inserted_at)}
    )
  end

  defp handle_change_max(user_id) do
    from(n in HandleChangeNotification,
      where: n.recipient_id == ^user_id,
      select: %{ts: max(n.inserted_at)}
    )
  end

  # New CV entries of the people this member follows (issue #980).
  defp cv_update_max(user_id) do
    user_id
    |> CvUpdates.feed_query()
    |> select([e], %{ts: max(e.inserted_at)})
  end

  # The "this is your username" welcome note (see username_items/3), keyed on
  # welcome_notified_at; MAX skips the NULL of a not-yet-welcomed account.
  defp username_max(user_id) do
    from(u in User,
      where: u.id == ^user_id,
      select: %{ts: max(u.welcome_notified_at)}
    )
  end

  @doc """
  Record that `user_id` has seen `post_id`, so the notifications *about* that
  post stop counting as unread (`notification_post_reads`).

  Called from `Vutuv.Posts` whenever a member answers, likes, bookmarks or
  reposts a post: all four are deliberate acts on a post they were looking at,
  which makes "you were mentioned here" or "somebody answered this" news they
  already have. The feed's "Show N new posts" pill marks the same way (via
  `mark_posts_seen/2`): revealing a batch is the member choosing to look at
  exactly those posts. Idempotent (the four actions are toggles that may fire
  again), and a no-op for a missing member or post.

  The badge is not decremented here — `:notifications_changed` tells the shell
  to recount from the source, the same way a silently removed event does, so
  the two can never drift. Only a fresh mark broadcasts; the repeat changes
  nothing to recount.
  """
  def mark_post_seen(nil, _post_id), do: :ok
  def mark_post_seen(_user_id, nil), do: :ok

  def mark_post_seen(user_id, post_id) when is_binary(user_id) and is_binary(post_id),
    do: mark_posts_seen(user_id, [post_id])

  @doc """
  Batch form of `mark_post_seen/2`, for the feed's "Show N new posts" pill:
  revealing the batch is one act of looking, so all fresh marks together
  broadcast a single `:notifications_changed` recount instead of one per post.
  Same semantics otherwise — idempotent, and silent when nothing was new.
  """
  def mark_posts_seen(nil, _post_ids), do: :ok

  def mark_posts_seen(user_id, post_ids) when is_binary(user_id) and is_list(post_ids) do
    fresh =
      Enum.count(post_ids, fn post_id ->
        match?(
          {:inserted, _row},
          Engagement.insert_if_new(
            NotificationPostRead,
            %{user_id: user_id, post_id: post_id},
            [:user_id, :post_id]
          )
        )
      end)

    if fresh > 0, do: broadcast(user_id, :notifications_changed), else: :ok
  end

  @doc """
  Which of `post_ids` the member has already seen (`mark_post_seen/2`), as a
  `MapSet`. One query for a whole notifications page, so its rows can render
  the individually-read ones as read; empty in, empty out.
  """
  def seen_post_ids(_user_id, []), do: MapSet.new()
  def seen_post_ids(nil, _post_ids), do: MapSet.new()

  def seen_post_ids(user_id, post_ids) do
    from(s in NotificationPostRead,
      where: s.user_id == ^user_id and s.post_id in ^post_ids,
      select: s.post_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  The post a feed item is *about* — the one the member would engage with to
  prove they have seen it, and the key `mark_post_seen/2` marks.

  Only the three kinds whose subject is somebody else's post have one: the
  answer to your post, the answer elsewhere in your thread, and the post that
  named you. A "like" names your own post instead, and engaging with your own
  post says nothing about having seen who liked it, so it has none.
  """
  def subject_post_id(%{kind: kind} = item) when kind in ~w(reply thread),
    do: Map.get(item, :reply_post_id)

  def subject_post_id(%{kind: "mention"} = item), do: Map.get(item, :post_id)
  def subject_post_id(_item), do: nil

  @doc """
  Record that `user_id` has seen the single event named by `kind` and
  `source_id`, so it stops counting as unread.

  Written when the member clicks the **browser notification** that announced
  it (issue #1249 shipped the popup; this is the half that makes clicking one
  mean something). A popup carries exactly one event, so the click is a
  statement about that event and about nothing else waiting on the bell —
  which is why this writes a per-event exception instead of moving the read
  marker, and why the badge drops by one rather than to zero.

  `kind` is a notification kind (`kinds/0`) or the pseudo-kind
  `"report_protection_restored"`; `source_id` the id of the row the feed
  derives the event from. Unknown kinds and non-UUID ids are ignored rather
  than stored, since both arrive from the browser. Idempotent — a second click
  on the same popup changes nothing and stays silent, the same way a repeated
  `mark_post_seen/2` does.

  The badge is not decremented here: `:notifications_changed` tells the shell
  to recount from the source, so the tally and the feed can never drift.
  """
  def mark_notification_seen(user_id, kind, source_id)
      when is_binary(user_id) and is_binary(kind) and is_binary(source_id) do
    with true <- kind in dismissable_kinds(),
         {:ok, id} <- Vutuv.UUIDv7.cast(source_id),
         {:inserted, _row} <-
           Engagement.insert_if_new(
             NotificationDismissal,
             %{user_id: user_id, kind: kind, source_id: id},
             [:user_id, :kind, :source_id]
           ) do
      broadcast(user_id, :notifications_changed)
    else
      _ -> :ok
    end
  end

  # Total on purpose: the three arguments come off the wire, so a nil or a
  # number is an ordinary thing to be handed, not a bug to crash the socket on.
  def mark_notification_seen(_user_id, _kind, _source_id), do: :ok

  @doc """
  How a live-pushed notification names itself to `mark_notification_seen/3`:
  `%{kind: kind, source_id: id}`, or nil for an event the tally cannot single
  out again.

  The browser notification carries this back when the member clicks it, so the
  kind vocabulary stays here rather than being spelled again in the shell.
  """
  def dismiss_ref(%{kind: kind} = notification) do
    kind = dismiss_kind(kind, notification)
    source_id = notification[:source_id]

    if kind in dismissable_kinds() and is_binary(source_id),
      do: %{kind: kind, source_id: source_id}
  end

  def dismiss_ref(_notification), do: nil

  # The severance row behind `report_protection` produces two events at
  # different times, so the pair (kind, source_id) needs the family to tell
  # them apart — dismissing "your report severed this" must not also dismiss
  # "and a rejected case restored it" months later.
  defp dismiss_kind("report_protection", %{status: "restored"}), do: "report_protection_restored"
  defp dismiss_kind(kind, _notification), do: kind

  @doc """
  The id one feed item carries: its kind (or pseudo-kind) and the id of the row
  it derives from, which is also what a dismissal stores. Every `*_items/3`
  builder composes its `:id` through here, so the two can only agree.
  """
  def event_id(kind, source_id), do: "#{id_prefix(kind)}-#{source_id}"

  # The prefixes predate the kind strings and differ from them in spelling
  # (dashes, not underscores); they are part of the identity of a rendered row,
  # so they are kept as they were rather than normalised.
  defp id_prefix("organization_role"), do: "organization-role"
  defp id_prefix("image_rejected"), do: "image-rejected"
  defp id_prefix("report_protection"), do: "report-protection"
  defp id_prefix("report_protection_restored"), do: "report-protection-restored"
  defp id_prefix("handle_change"), do: "handle-change"
  defp id_prefix("reference_check"), do: "reference-check"
  defp id_prefix("cv_update"), do: "cv-update"
  defp id_prefix(kind), do: kind

  @doc """
  The kinds a dismissal can name, read straight off the registry's `dismiss`
  entries — every kind with a single source row behind it, which is all of them
  but `cv_update`, plus the second name `report_protection` needs for its
  restore half. A kind cannot end up storing dismissals the tally then ignores,
  because both answers come from the same declaration.
  """
  def dismissable_kinds do
    for spec <- kind_specs(Vutuv.UUIDv7.generate()),
        {kind, _shape} <- spec.dismiss,
        do: kind
  end

  @doc """
  Which of the member's notifications are individually dismissed
  (`mark_notification_seen/3`), as a `MapSet` of `event_id/2` strings — the
  same ids the feed items carry, so a page can render those rows as read. One
  query, and empty for a logged-out visitor.
  """
  def dismissed_event_ids(nil), do: MapSet.new()

  def dismissed_event_ids(user_id) do
    from(d in NotificationDismissal,
      where: d.user_id == ^user_id,
      select: {d.kind, d.source_id}
    )
    |> Repo.all()
    |> MapSet.new(fn {kind, source_id} -> event_id(kind, source_id) end)
  end

  @doc "Tell a user's shell their messages were just read (clears the badge)."
  def mark_messages_read(party), do: broadcast(party, :messages_read)

  @doc "Push a new in-app notification to `user_id`."
  def notify(nil, _notification), do: :ok

  def notify(user_id, %{} = notification) do
    notification = with_event_id(notification)

    # The one place a notification is announced, which is why both Web Push
    # fan-outs hang here rather than at each of the twenty callers: a push
    # cannot then drift out of step with what the website shows. Two of them,
    # because the two kinds of client are subscribed differently — a
    # third-party phone client by its access token, this installation's own
    # installed app by the browser endpoint alone (issue #1729).
    PushDispatcher.dispatch(user_id, notification)
    WebPushDispatcher.dispatch(user_id, notification)
    broadcast(user_id, {:new_notification, notification})
  end

  # A live push and the feed row it will become are the same event, so they get
  # the same id — which is what lets an open notifications page replace the row
  # rather than stack a second one, and what `dismiss_ref/1` hands back when the
  # member clicks the popup. Kinds that already carry an id (the CV sitting,
  # whose id is a group and not a row) keep it.
  defp with_event_id(%{kind: kind, source_id: source_id} = notification)
       when is_binary(source_id),
       do: Map.put_new(notification, :id, event_id(kind, source_id))

  defp with_event_id(notification), do: notification

  @doc """
  Convenience: a "started following you" notification for the followee. Carries
  the actor's name, route param, and avatar so the notifications page can link
  to the follower's profile and show their picture.
  """
  def notify_new_follower(followee_id, follower, follow_id \\ nil) do
    Vutuv.Webhooks.emit(followee_id, "follower.created", %{
      "follower" => actor_param(follower)
    })

    notify(
      followee_id,
      Map.merge(actor_fields(follower), %{
        kind: "follower",
        text: "started following you.",
        source_id: follow_id,
        at: DateTime.utc_now()
      })
    )

    :ok
  end

  @doc """
  Convenience: a "made you an admin of <organization>" notification for the member
  who was granted an organization role (issue #930). The derived feed already picks up
  the `organization_roles` row; this live push updates the open session's badge and
  toast at grant time. The actor is the granting member, rendered as a linked
  `@handle`.
  """
  def notify_organization_role(
        user_id,
        granter,
        %Organization{} = organization,
        role,
        role_id \\ nil
      ) do
    notify(
      user_id,
      Map.merge(actor_fields(granter), %{
        kind: "organization_role",
        role: role,
        source_id: role_id,
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
        source_id: notification.id,
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

  @doc """
  The finished AI review of one Arbeitszeugnis, pushed to the member's open
  page and mailed to them.

  The one notification here with no actor: nobody did this *to* the member,
  they asked for it and were told they could close the page. A review takes
  minutes, more with a queue in front of it, so this is the other half of that
  promise — and the email is the half that works after they logged out.

  The grade rides along because it is the fact they waited for; the report
  itself never travels by mail, being a long legal reading of a private
  document.

  Nothing is mailed from here. Like every other kind, this reaches an inbox
  only through `Vutuv.Activity.Digest`, and only for a member who was away long
  enough to have missed it.
  """
  def notify_reference_check(%{user_id: user_id} = check, reference) do
    grade = Check.grade_span(check)

    notify(user_id, %{
      kind: "reference_check",
      source_id: check.id,
      at: check.finished_at || DateTime.utc_now(),
      job_reference_id: reference.id,
      title: reference.title,
      grade: grade
    })

    :ok
  end

  @doc ~S(Convenience: an "endorsed you for <tag>" notification for the tag's owner.)
  def notify_endorsement(owner_id, endorser, tag_name, endorsement_id \\ nil) do
    Vutuv.Webhooks.emit(owner_id, "endorsement.created", %{
      "endorser" => actor_param(endorser),
      "tag" => tag_name
    })

    notify(
      owner_id,
      Map.merge(actor_fields(endorser), %{
        kind: "endorsement",
        tag: tag_name,
        source_id: endorsement_id,
        text: "endorsed you for #{tag_name}.",
        at: DateTime.utc_now()
      })
    )

    :ok
  end

  @doc ~S"""
  Convenience: a "replied to your post" notification for the parent post's
  author. `post_id` is the parent post, so the notification can link to the
  thread the reply landed in.
  """
  def notify_reply(
        parent_author_id,
        replier,
        parent_post_id \\ nil,
        reply_post_id \\ nil,
        reply_ref_id \\ nil
      ) do
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
        # The `post_replies` row the feed counts — what a dismissal names.
        source_id: reply_ref_id,
        at: DateTime.utc_now()
      })
    )
  end

  @doc ~S"""
  Convenience: a "replied in a thread you posted in" notification for another
  participant of a thread — the root author or an earlier replier. The
  directly answered author gets `notify_reply/4` instead, never both.
  `reply_post_id` is the new reply, so the row can quote and link it;
  `root_post_id` keys the notification page's per-thread grouping.
  """
  def notify_thread_reply(user_id, replier, root_post_id, reply_post_id, reply_ref_id \\ nil) do
    notify(
      user_id,
      Map.merge(actor_fields(replier), %{
        kind: "thread",
        text: "replied in a thread you posted in.",
        root_post_id: root_post_id,
        reply_post_id: reply_post_id,
        source_id: reply_ref_id,
        at: DateTime.utc_now()
      })
    )
  end

  @doc ~S"""
  Convenience: a "replied to your post from another network" notification
  (issue #1069) — somebody on Mastodon or a comparable server answered a post of
  the member's, and the reply is now stored as a `Vutuv.Fediverse.Note`.

  The live push only; the durable half is the note row itself, which
  `fediverse_reply_items/3` derives the notification from. That is the point of
  sourcing this kind straight from the notes table: when the note is deleted
  (reported, expired, withdrawn upstream), its notification goes with it and
  there is no second place to remember.

  The actor is a stranger with no vutuv profile, so the item carries their
  display name, their `@handle@host` and a link **out** to their account, and
  none of the local `actor_param` / avatar fields a member's actor would.
  """
  def notify_fediverse_reply(%User{} = user, post, note) do
    notify(
      user.id,
      Map.merge(remote_actor_fields(note), %{
        kind: "fediverse_reply",
        text: "replied to your post from another network.",
        post_id: post.id,
        note_id: note.id,
        source_id: note.id,
        at: note.received_at
      })
    )
  end

  @doc ~S"""
  Convenience: a "favourited / shared your post from another network"
  notification (issue #1068) — the answer coming back from Mastodon and its
  kin, now stored as a `Vutuv.Fediverse.Reaction`.

  Same shape as `notify_fediverse_reply/3`, and for the same reason: the live
  push only, with the reaction row itself as the durable half that
  `fediverse_reaction_items/3` derives the feed entry from. An upstream `Undo`
  deletes the row, and the notification goes with it — there is no second place
  that has to remember to forget.

  `reaction_kind` rides along because the sentence turns on it: a favourite and
  a re-share are not the same news.
  """
  def notify_fediverse_reaction(%User{} = user, post, reaction) do
    notify(
      user.id,
      Map.merge(remote_actor_fields(reaction), %{
        kind: "fediverse_reaction",
        text: "reacted to your post from another network.",
        post_id: post.id,
        reaction_id: reaction.id,
        source_id: reaction.id,
        reaction_kind: reaction.kind,
        at: reaction.received_at
      })
    )
  end

  @doc ~S"""
  Convenience: a "mentioned you in a post" notification for a member the post's
  body names by `@handle`. `post_id` is that post — written by the actor, not by
  the recipient, so the row links it under the **author's** profile.

  Pushed by `Vutuv.Posts` only for names it just added, so an edit that leaves a
  mention untouched never notifies twice. The durable half is the
  `post_mentions` row written alongside it (`mention_items/3`).
  """
  def notify_mention(user_id, author, post_id, mention_id \\ nil) do
    notify(
      user_id,
      Map.merge(actor_fields(author), %{
        kind: "mention",
        text: "mentioned you in a post.",
        post_id: post_id,
        source_id: mention_id,
        at: DateTime.utc_now()
      })
    )
  end

  @doc ~S(Convenience: a "liked your post" notification for the post's author.)
  def notify_like(author_id, liker, post_id, like_id \\ nil) do
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
        source_id: like_id,
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
  def notify_connection(user_id, other, follow_id \\ nil) do
    Vutuv.Webhooks.emit(user_id, "connection.created", %{
      "with" => actor_param(other)
    })

    notify(
      user_id,
      Map.merge(actor_fields(other), %{
        kind: "connection",
        text: "is now connected with you.",
        # The pair's id is the later of its two follows, which is the one just
        # written — see `count_connections/3`.
        source_id: follow_id,
        at: DateTime.utc_now()
      })
    )

    :ok
  end

  @doc """
  Tells a reporter that their report severed ("severed") or a rejected case
  restored ("restored") the relationship to the reported member. The actor
  fields carry the *reported* member so the feed entry can name and link
  @their_handle. The durable counterpart is derived from the severance rows
  (see `report_protection_items/3`).
  """
  def notify_report_protection(reporter_id, reported_user, status, severance_id \\ nil) do
    notify(
      reporter_id,
      Map.merge(actor_fields(reported_user), %{
        kind: "report_protection",
        status: status,
        source_id: severance_id,
        at: DateTime.utc_now()
      })
    )
  end

  # Nothing here sends email. Every notification kind reaches an inbox through
  # one path, `Vutuv.Activity.Digest`, and only for a member who was away long
  # enough to have missed it in the app. This module's job ends at the badge.

  ## Derived notifications feed

  @doc """
  One page of the user's notification feed (newest first) plus pagination
  state for a "Load more" UI: `%{entries: [...], more?: boolean,
  next_cursor: cursor | nil}`. Pass the returned cursor back as `cursor:` to
  get the next-older page.

  The feed is derived straight from its source tables — followers
  (`follows`), endorsements (`user_tag_endorsements`, with the tag's name),
  connections (accepted `connections` rows, timestamped at acceptance) and
  replies (`post_replies`, minus self-replies; answers elsewhere in a thread
  the user writes in surface as the separate "thread" kind) — so it includes
  events from before this feature existed.
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
      for spec <- kind_specs(user_id), kinds == nil or spec.kind in kinds, do: spec.items

    if page,
      do: Vutuv.FeedPage.paginate_offset(sources, limit, (max(page, 1) - 1) * limit),
      else: Vutuv.FeedPage.paginate(sources, limit, Keyword.get(opts, :cursor))
  end

  @doc """
  The notification kinds and the member preference each one answers to, as
  `%{kind => field | nil}`. Public so `Vutuv.Activity.Digest` and its test can
  read the registry rather than keeping a second copy of it.
  """
  def kind_email_prefs do
    # The registry builds each kind's queries as it goes, and those queries
    # need *a* member id — Ecto refuses to compare a column with nil. Nothing
    # here runs them, so a throwaway id is enough, and reading the same list
    # the feed reads is what keeps this from becoming a second registry.
    throwaway = Vutuv.UUIDv7.generate()

    for spec <- kind_specs(throwaway), into: %{}, do: {spec.kind, Map.fetch!(spec, :email_pref)}
  end

  @doc """
  One page of the feed for the digest: everything that happened after `since`,
  newest first, capped at `limit`.

  `since` is a `DateTime`; entries carry `:at` as one too. The feed sources are
  cursor-paginated from the newest end, so this walks back until it passes
  `since` rather than filtering per kind — which keeps the registry the only
  place that knows what a kind is.

  Entries the member triggered themselves are dropped. An event whose actor is
  the member is news to everybody except them, and a mail about their own click
  is the worst place to learn that — the badge already stays quiet for those
  (`count_connections/3`). A source marks such an entry with
  `self_triggered?: true` and needs no other arrangement here, which is what
  keeps `Vutuv.Activity.Digest` free of per-kind rules. Today only the vernetzt
  pair a member completed themselves sets it; every other kind has somebody
  else as its actor, and self-replies and self-endorsements never become
  entries at all.
  """
  def events_since(user_id, since, limit) do
    %{entries: entries} = notifications_page(user_id, limit: limit)

    Enum.filter(entries, fn entry ->
      after?(entry[:at], since) and entry[:self_triggered?] != true
    end)
  end

  defp after?(nil, _since), do: false
  defp after?(_at, nil), do: true

  defp after?(%DateTime{} = at, %DateTime{} = since), do: DateTime.compare(at, since) == :gt

  defp after?(%NaiveDateTime{} = at, since),
    do: at |> DateTime.from_naive!("Etc/UTC") |> after?(since)

  defp after?(at, %NaiveDateTime{} = since),
    do: after?(at, DateTime.from_naive!(since, "Etc/UTC"))

  # THE registry of notification kinds. Every kind declares all four of its
  # derivations here — read-marker MAX arm(s), feed source, count query(ies),
  # dismissal shape — so a kind can no longer join one structure and silently
  # miss another,
  # which is exactly the badge-never-clears bug that shipped three times
  # (#980, #930, v7.200.1). `latest_event_at/1`, `notifications_page/2` and
  # `total_count/4` all read from this table and nowhere else.
  #
  #   * `max_arms` — `%{ts: ...}` MAX queries unioned into the read marker.
  #   * `items` — the feed source (a `Vutuv.FeedPage` fetch fun) keyed by the
  #     kind string its items carry, so `kinds:` can pick the subset to query.
  #     Entry order is the merge's tie-break order for same-second events
  #     (the merge sort is stable), so treat it as part of the interface.
  #   * `counts` — count queries summed into the badge tally, bounded by the
  #     same `read_at` the marker wrote.
  #   * `dismiss` — one entry per `counts` query saying how a per-event
  #     dismissal (`mark_notification_seen/3`) is excluded from it: `{kind,
  #     :id}` for the ordinary case, where the event's own row is the query's
  #     first binding, or `nil` for a kind with no single source row. The
  #     `kind` in the tuple is the dismissal's namespace and usually the kind
  #     itself; `report_protection` needs two because one row emits two
  #     events. Declaring it here rather than inside each count query is what
  #     makes `dismissable_kinds/0` derivable and stops a new kind from
  #     storing dismissals the tally then ignores.
  #   * `email_pref` — the `Vutuv.Accounts.User` field a member turns off to
  #     stop this kind reaching the digest mail (`Vutuv.Activity.Digest`), or
  #     `nil` for a kind that is shown in the app and never mailed. It lives
  #     here rather than in a map of its own for the same reason as the rest:
  #     adding a kind must be one edit in one place, and a kind that forgets
  #     this key fails `activity_digest_test.exs` instead of quietly never
  #     mailing anybody.
  #
  # Deliberate per-kind asymmetries, kept as they were:
  #
  #   * `report_protection` is ONE source emitting two event families
  #     (severed / restored) with different timestamp columns — so two max
  #     arms and two counts. That is why both list-valued keys are lists.
  #   * `unread?` marks the badge tally, as opposed to the pager's total, and
  #     switches on the "the member already knows this" exceptions. Two are
  #     per-kind: reply / thread / mention drop events about posts the member
  #     engaged with (`mark_post_seen/2` — the kinds whose subject is somebody
  #     else's post, `subject_post_id/1`), and `connection` drops the pair the
  #     member made mutual themselves. The third, `dismiss`, is applied to
  #     every kind at once in `total_count/4`.
  #   * `cv_update` counts sittings, not rows: its read-marker filter lives
  #     inside the grouped query (`CvUpdates.count_query/2`), not in `since/2`.
  #   * The fediverse kinds key on `received_at` (a :utc_datetime), `username`
  #     on `welcome_notified_at`, `connection` on the GREATEST of the two
  #     follow times — each per-kind helper owns its own boundary comparison.
  @doc """
  Every notification kind the registry produces.

  Derived from `kind_specs/3` itself, so a presentation surface can check its
  own coverage instead of keeping a second hand-maintained list — which had
  already drifted: `reference_check` was in the registry and in none of the
  notification page's filter tabs, so a live-pushed one was dropped for any
  reader not sitting on "All". The ids here only shape queries that are never
  run; the vocabulary is what is being asked for.
  """
  def kinds, do: Vutuv.UUIDv7.generate() |> kind_specs() |> Enum.map(& &1.kind)

  defp kind_specs(user_id, read_at \\ nil, unread? \\ false) do
    [
      %{
        kind: "follower",
        email_pref: :email_on_follower?,
        max_arms: [follower_max(user_id)],
        items: &follower_items(user_id, &1, &2),
        counts: [count_followers(user_id, read_at)],
        dismiss: [{"follower", :id}]
      },
      %{
        kind: "endorsement",
        email_pref: :email_on_endorsement?,
        max_arms: [endorsement_max(user_id)],
        items: &endorsement_items(user_id, &1, &2),
        counts: [count_endorsements(user_id, read_at)],
        dismiss: [{"endorsement", :id}]
      },
      %{
        kind: "connection",
        email_pref: :email_on_follower?,
        max_arms: [connection_max(user_id)],
        items: &connection_items(user_id, &1, &2),
        counts: [count_connections(user_id, read_at, unread?)],
        # A pair has no row of its own: its id, here and on the entry
        # `connection_items/3` builds, is the later of the two follows.
        dismiss: [{"connection", :later_follow}]
      },
      %{
        kind: "reply",
        email_pref: nil,
        max_arms: [reply_max(user_id)],
        items: &reply_items(user_id, &1, &2),
        counts: [count_replies(user_id, read_at, unread?)],
        dismiss: [{"reply", :id}]
      },
      %{
        kind: "thread",
        email_pref: nil,
        max_arms: [thread_max(user_id)],
        items: &thread_items(user_id, &1, &2),
        counts: [count_thread_replies(user_id, read_at, unread?)],
        dismiss: [{"thread", :id}]
      },
      %{
        kind: "mention",
        email_pref: nil,
        max_arms: [mention_max(user_id)],
        items: &mention_items(user_id, &1, &2),
        counts: [count_mentions(user_id, read_at, unread?)],
        dismiss: [{"mention", :id}]
      },
      %{
        kind: "fediverse_reply",
        email_pref: nil,
        max_arms: [fediverse_reply_max(user_id)],
        items: &fediverse_reply_items(user_id, &1, &2),
        counts: [count_fediverse_replies(user_id, read_at)],
        dismiss: [{"fediverse_reply", :id}]
      },
      %{
        kind: "fediverse_reaction",
        email_pref: nil,
        max_arms: [fediverse_reaction_max(user_id)],
        items: &fediverse_reaction_items(user_id, &1, &2),
        counts: [count_fediverse_reactions(user_id, read_at)],
        dismiss: [{"fediverse_reaction", :id}]
      },
      %{
        kind: "like",
        email_pref: nil,
        max_arms: [like_max(user_id)],
        items: &like_items(user_id, &1, &2),
        counts: [count_likes(user_id, read_at)],
        dismiss: [{"like", :id}]
      },
      %{
        kind: "organization_role",
        email_pref: nil,
        max_arms: [organization_role_max(user_id)],
        items: &organization_role_items(user_id, &1, &2),
        counts: [count_organization_roles(user_id, read_at)],
        dismiss: [{"organization_role", :id}]
      },
      %{
        kind: "moderation",
        email_pref: nil,
        max_arms: [moderation_max(user_id)],
        items: &moderation_items(user_id, &1, &2),
        counts: [count_moderation(user_id, read_at)],
        dismiss: [{"moderation", :id}]
      },
      %{
        kind: "image_rejected",
        email_pref: nil,
        max_arms: [image_rejected_max(user_id)],
        items: &image_rejected_items(user_id, &1, &2),
        counts: [count_image_rejections(user_id, read_at)],
        dismiss: [{"image_rejected", :id}]
      },
      %{
        kind: "report_protection",
        email_pref: nil,
        max_arms: [severance_max(user_id), severance_restore_max(user_id)],
        items: &report_protection_items(user_id, &1, &2),
        counts: [count_severances(user_id, read_at), count_severance_restores(user_id, read_at)],
        # One severance row, two events: the restore half needs a namespace of
        # its own or dismissing the severance would dismiss it too.
        dismiss: [{"report_protection", :id}, {"report_protection_restored", :id}]
      },
      %{
        kind: "handle_change",
        email_pref: nil,
        max_arms: [handle_change_max(user_id)],
        items: &handle_change_items(user_id, &1, &2),
        counts: [count_handle_changes(user_id, read_at)],
        dismiss: [{"handle_change", :id}]
      },
      %{
        kind: "cv_update",
        email_pref: nil,
        max_arms: [cv_update_max(user_id)],
        items: &cv_update_items(user_id, &1, &2),
        counts: [count_cv_updates(user_id, read_at)],
        # The one kind with no source row: an item is a *sitting*, several CV
        # rows grouped in Elixir under a synthesised id, so there is nothing
        # for the tally to exclude and clicking its popup leaves the badge be.
        dismiss: [nil]
      },
      %{
        kind: "username",
        email_pref: nil,
        max_arms: [username_max(user_id)],
        items: &username_items(user_id, &1, &2),
        counts: [count_username(user_id, read_at)],
        dismiss: [{"username", :id}]
      },
      %{
        kind: "reference_check",
        email_pref: :email_on_reference_check?,
        max_arms: [reference_check_max(user_id)],
        items: &reference_check_items(user_id, &1, &2),
        counts: [count_reference_checks(user_id, read_at)],
        dismiss: [{"reference_check", :id}]
      }
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

  def notifications_count(user_id, kinds), do: total_count(user_id, nil, kinds, false)

  @doc """
  How many feed events are newer than the user's read marker (all of them when
  the marker is NULL) **and** not about a post the member has already seen.
  Zero for a logged-out visitor.

  The second half is what makes the badge mean "things you have not looked at"
  rather than "things since your last visit to /notifications": answering,
  liking, bookmarking or reposting a post marks it seen (`mark_post_seen/2`)
  and its event drops out of the tally right there in the feed.
  """
  def unread_notification_count(nil), do: 0

  # A caller already holding the freshly loaded `%User{}` (the shell's connected
  # mount, the API poll) skips the marker read; the id clause below re-reads the
  # marker and stays the right one for recounts, where the marker may have moved
  # since the struct was loaded.
  def unread_notification_count(%User{id: user_id, notifications_read_at: read_at}),
    do: total_count(user_id, read_at, nil, true)

  def unread_notification_count(user_id) do
    read_at = Repo.one(from(u in User, where: u.id == ^user_id, select: u.notifications_read_at))
    total_count(user_id, read_at, nil, true)
  end

  # The feed sources are counted in a single round trip: each count is a
  # scalar subquery, summed in one SELECT. unread_notification_count/1 still
  # needs one prior read for the marker, so it ends up at 2 queries;
  # notifications_count/2 needs no marker and so runs in 1 query. The
  # strict `> read_at` unread filter and the GREATEST-anchored mutuality
  # timestamp are unchanged — only the round trips collapse.
  #
  # `kinds` picks the subset to count via the registry (`kind_specs/3`), so a
  # filter narrows the feed and its total the same way; the sum is built with
  # dynamics so the filtered case stays one query too.
  #
  # `unread?` additionally drops the events whose post the member has already
  # engaged with (`mark_post_seen/2`). It is deliberately not derived from
  # `read_at` — that one is nil for a member who never opened /notifications,
  # who still wants the per-post exceptions applied.
  defp total_count(user_id, read_at, kinds, unread?) do
    counts =
      for spec <- kind_specs(user_id, read_at, unread?),
          kinds == nil or spec.kind in kinds,
          {count, dismiss} <- Enum.zip(spec.counts, spec.dismiss),
          do: unless_dismissed(count, user_id, dismiss, unread?)

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

  # The actor join deliberately happens **after** the order/limit, via a
  # subquery. Joining users straight onto the follows rows makes Postgres build
  # the whole candidate set first — for a member with many followers that means
  # hash-joining the entire users table (a full scan on every notification
  # page) only to discard all but `limit` of the result. Ordering and limiting
  # the cheap follows rows first and attaching the actor to the survivors turns
  # it into `limit` primary-key lookups: measured 9.4 ms -> 0.6 ms on the
  # production data. `connection_items/3` below is the same shape.
  # A follower is a member **or** a page (issue #1336). Both id columns ride
  # along and the outer query LEFT joins each, so a page row is built from the
  # organization rather than dropped — which is what it used to be, while
  # `count_followers/2` counted it: badge one, list empty, and a badge that lies
  # once is a badge nobody trusts again.
  defp follower_items(user_id, limit, cursor) do
    newest =
      from(c in Follow,
        where: c.followee_id == ^user_id,
        order_by: [desc: c.inserted_at, desc: c.id],
        limit: ^limit,
        select: %{
          id: c.id,
          at: c.inserted_at,
          actor_id: c.follower_id,
          actor_organization_id: c.follower_organization_id
        }
      )
      |> at_or_before(cursor)

    from(e in subquery(newest))
    |> join_party(:actor_id, :actor_organization_id)
    |> where([e, f, o], shown_party(f, o))
    |> order_by([e], desc: e.at, desc: e.id)
    |> select([e, f, o], {e.id, e.at, struct(f, ^User.listing_fields()), o})
    |> Repo.all()
    |> Enum.map(fn {id, at, follower, organization} ->
      actor_item(event_id("follower", id), "follower", at, follower || organization)
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
      event_id("endorsement", id)
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
    mutual =
      from(out in Follow,
        join: back in Follow,
        on: back.follower_id == out.followee_id and back.followee_id == out.follower_id,
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
          actor_id: out.followee_id,
          # Who closed the circle: the member's own follow being the later row
          # makes this item something they already know (see
          # `count_connections/3` for why the ids answer this and the seconds-
          # resolution timestamps cannot).
          self_closed: out.id > back.id
        }
      )

    mutual =
      if cursor,
        do:
          where(
            mutual,
            [out, back],
            fragment("GREATEST(?, ?)", out.inserted_at, back.inserted_at) <= ^cursor.at
          ),
        else: mutual

    # Same two-step shape as `follower_items/3`: the users join is kept out of
    # the ordered/limited half so it runs over `limit` rows, not every mutual
    # follow (measured 6.0 ms -> 0.8 ms).
    from(e in subquery(mutual),
      join: u in User,
      on: u.id == e.actor_id,
      order_by: [desc: e.at, desc: e.id],
      select: %{
        id: e.id,
        at: e.at,
        friend: struct(u, ^User.listing_fields()),
        self_closed: e.self_closed
      }
    )
    |> Repo.all()
    |> Enum.map(fn %{id: id, at: at, friend: friend, self_closed: self_closed} ->
      event_id("connection", id)
      |> actor_item("connection", at, friend)
      |> Map.put(:self_triggered?, self_closed)
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
      event_id("reply", id)
      |> actor_item("reply", at, replier)
      # The parent (the recipient's own post the row links to) and the reply
      # itself, so the row can quote both.
      |> Map.put(:post_id, parent_post_id)
      |> Map.put(:reply_post_id, reply_post_id)
    end)
  end

  # New replies elsewhere in threads the user writes in: every reply in a
  # thread they rooted or answered in earlier — except their own replies and
  # replies answering them directly (those are "reply" events, never both).
  defp thread_items(user_id, limit, cursor) do
    thread_replies(user_id)
    |> join(:inner, [reply_post: reply], replier in User,
      on: replier.id == reply.user_id,
      as: :replier
    )
    |> order_by([thread_ref: r], desc: r.inserted_at, desc: r.id)
    |> limit(^limit)
    |> select(
      [thread_ref: r, replier: replier],
      {r.id, r.inserted_at, struct(replier, ^User.listing_fields()), r.root_post_id, r.post_id}
    )
    |> at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, replier, root_post_id, reply_post_id} ->
      event_id("thread", id)
      |> actor_item("thread", at, replier)
      # The thread (grouping key) and the reply itself (the quote + link).
      |> Map.put(:root_post_id, root_post_id)
      |> Map.put(:reply_post_id, reply_post_id)
      # A replier is always a member today (a page's post cannot be answered),
      # so this matches what the view built by hand — it just stops being a
      # second place that has to be remembered if that ever widens.
      |> Map.put(:post_path, post_path(replier, reply_post_id))
    end)
  end

  # Posts that name the user with `@handle` (issue: mention notifications). The
  # rows come from `post_mentions`, reconciled at save time by `Vutuv.Posts` —
  # deriving them here would mean an ILIKE over every post on every unread
  # count. Newest first, actor = the post's author.
  # Both joins are LEFT: whoever named the member is a member or an
  # organization (issue #1334), exactly one of the two per row, and an inner
  # join to `users` dropped every mention a page made.
  defp mention_items(user_id, limit, cursor) do
    mention_events(user_id)
    |> join(:left, [mention_post: p], author in User, on: author.id == p.user_id, as: :author)
    |> join(:left, [mention_post: p], org in Organization,
      on: org.id == p.organization_id,
      as: :mention_organization
    )
    |> order_by([mention: m], desc: m.inserted_at, desc: m.id)
    |> limit(^limit)
    |> select(
      [mention: m, author: author, mention_organization: org],
      {m.id, m.inserted_at, struct(author, ^User.listing_fields()), org, m.post_id}
    )
    |> at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, author, organization, post_id} ->
      actor = mention_actor(author, organization)

      event_id("mention", id)
      |> actor_item("mention", at, actor)
      # The post that named them — the author's, not the recipient's.
      |> Map.put(:post_id, post_id)
      |> Map.put(:post_path, post_path(actor, post_id))
    end)
  end

  # The row carries its own link, because the view cannot build one: it holds
  # `actor_param`, which for a page is the slug, and the deeper post path is
  # member-only — so a mention written by a page linked into the member
  # namespace and 404ed. `Posts.path/2` owns both shapes; here is the one place
  # that has the actor struct to hand it.
  defp post_path(actor, post_id) when is_binary(post_id), do: Posts.path(actor, post_id)
  defp post_path(_actor, _post_id), do: nil

  # A missed LEFT join still yields a `%User{}` with every field nil rather than
  # nil itself, so the id is what says which side actually matched.
  defp mention_actor(%User{id: id} = author, _organization) when is_binary(id), do: author
  defp mention_actor(_author, organization), do: organization

  # Replies written on other networks under the member's posts (issue #1069),
  # derived **straight from the notes table** rather than from a stored
  # notification row. That is deliberate: when the note goes — reported,
  # expired, withdrawn upstream, the server blocked — its notification goes with
  # it, and there is no second place that has to remember to forget.
  #
  # No viewer scoping is needed here: every note under the member's own posts is
  # theirs to see, including the ones addressed to them alone (issue #1071).
  defp fediverse_reply_items(user_id, limit, cursor) do
    user_id
    |> fediverse_reply_events()
    |> order_by([note: n], desc: n.received_at, desc: n.id)
    |> limit(^limit)
    |> select([note: n], n)
    |> note_at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn note ->
      note
      |> remote_actor_fields()
      |> Map.merge(%{
        id: event_id("fediverse_reply", note.id),
        kind: "fediverse_reply",
        # The merged feed sorts and cursors on NaiveDateTime (Vutuv.FeedPage);
        # this is the one source whose column is a DateTime.
        at: DateTime.to_naive(note.received_at),
        post_id: note.post_id,
        note_id: note.id,
        note_audience: note.audience,
        note_text: note.summary || note.content_text
      })
    end)
  end

  defp fediverse_reply_events(user_id) do
    from(n in Note,
      as: :note,
      join: p in Post,
      on: p.id == n.post_id,
      where: p.user_id == ^user_id
    )
  end

  defp count_fediverse_replies(user_id, read_at) do
    user_id
    |> fediverse_reply_events()
    |> select([note: n], %{count: count()})
    |> note_since(read_at)
  end

  # Favourites and re-shares from other networks (issue #1068), sourced straight
  # from the reaction rows for the same reason the replies are: an upstream
  # `Undo`, a deleted post or a member switching the counts off deletes the row,
  # and the notification goes with it.
  defp fediverse_reaction_items(user_id, limit, cursor) do
    user_id
    |> fediverse_reaction_events()
    |> order_by([note: r], desc: r.received_at, desc: r.id)
    |> limit(^limit)
    |> select([note: r], r)
    |> note_at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn reaction ->
      reaction
      |> remote_actor_fields()
      |> Map.merge(%{
        id: event_id("fediverse_reaction", reaction.id),
        kind: "fediverse_reaction",
        at: DateTime.to_naive(reaction.received_at),
        post_id: reaction.post_id,
        reaction_id: reaction.id,
        reaction_kind: reaction.kind
      })
    end)
  end

  # Named `:note` like the reply source so both share `note_at_or_before/2` and
  # `note_since/2` — the same `received_at` boundary conversion, one copy.
  defp fediverse_reaction_events(user_id) do
    from(r in Reaction,
      as: :note,
      join: p in Post,
      on: p.id == r.post_id,
      where: p.user_id == ^user_id
    )
  end

  defp count_fediverse_reactions(user_id, read_at) do
    user_id
    |> fediverse_reaction_events()
    |> select([note: r], %{count: count()})
    |> note_since(read_at)
  end

  # `received_at` is a :utc_datetime while the feed's cursor and the read marker
  # are NaiveDateTimes, so both boundaries are converted rather than left to an
  # implicit cast.
  defp note_at_or_before(query, nil), do: query

  defp note_at_or_before(query, %{at: at}),
    do: where(query, [note: n], n.received_at <= ^to_utc(at))

  defp note_since(query, nil), do: query
  defp note_since(query, read_at), do: where(query, [note: n], n.received_at > ^to_utc(read_at))

  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp to_utc(%DateTime{} = at), do: at

  # The base scope behind the "mention" kind, shared by items / count / read
  # marker. The write side already excludes self-mentions and posts the member
  # cannot see (both are the post's own business, re-derived on every edit);
  # what is left here is what can change *after* the post was written:
  #
  #   * a **block** either way, filtered like thread events filter it, and
  #   * the precedence rule — a post that answers the member directly is
  #     already the stronger "reply" event, so it never also mentions. One
  #     post, one row; `thread_replies/1` yields to a mention the same way.
  defp mention_events(user_id) do
    from(m in PostMention,
      as: :mention,
      join: p in Post,
      on: p.id == m.post_id,
      as: :mention_post,
      where: m.user_id == ^user_id,
      where:
        not exists(
          from(r in PostReply,
            where: r.post_id == parent_as(:mention).post_id and r.parent_author_id == ^user_id,
            select: 1
          )
        ),
      # The block filter is about the *member* who named you. An organization
      # post has no member author, and `NULL NOT IN (…)` is NULL — never true —
      # so without the `is_nil` branch every mention by a page would silently
      # vanish from both this list and its unread count (issue #1334).
      where: is_nil(p.user_id) or p.user_id not in subquery(blocked_either_way(user_id))
    )
  end

  # The base scope behind the "thread" kind, shared by items / count / read
  # marker. A qualifying reply: sits in a thread (root known), is not the
  # user's own, does not answer the user directly, does not name the user (that
  # is the louder "mention" event — never both for one post), its author has no
  # block either way with the user, and the user had already written in the
  # thread when it landed — they authored the root, or an earlier reply
  # (replies from before they joined were on screen when they replied; not
  # news).
  defp thread_replies(user_id) do
    from(r in PostReply,
      as: :thread_ref,
      join: reply in Post,
      on: reply.id == r.post_id,
      as: :reply_post,
      # The reader's opt-out (issue #1025): with the switch off, this whole
      # source yields nothing — feed and unread count both build on it. A
      # constant subquery, so it costs no extra round trip and no caller change.
      where:
        exists(
          from(reader in User,
            where: reader.id == ^user_id and reader.thread_notifications?,
            select: 1
          )
        ),
      where: not is_nil(r.root_post_id),
      where: reply.user_id != ^user_id,
      where: is_nil(r.parent_author_id) or r.parent_author_id != ^user_id,
      where:
        not exists(
          from(m in PostMention,
            where: m.post_id == parent_as(:thread_ref).post_id and m.user_id == ^user_id,
            select: 1
          )
        ),
      where:
        exists(
          from(root in Post,
            where: root.id == parent_as(:thread_ref).root_post_id and root.user_id == ^user_id,
            select: 1
          )
        ) or
          exists(
            from(mine in PostReply,
              join: mp in Post,
              on: mp.id == mine.post_id,
              where:
                mine.root_post_id == parent_as(:thread_ref).root_post_id and
                  mp.user_id == ^user_id and
                  mine.inserted_at <= parent_as(:thread_ref).inserted_at,
              select: 1
            )
          ),
      where: reply.user_id not in subquery(blocked_either_way(user_id))
    )
  end

  # Everyone with a block either way to `user_id`. Thread events are the one
  # feed source whose actor needs no prior relation to the user (they answered
  # a *third* participant), so a blocked member could otherwise surface here —
  # the same exclusion the post feed applies. The "either direction" filter is
  # owned by Vutuv.Social; this only adds the select returning the other
  # party's id for the `NOT IN` subquery.
  defp blocked_either_way(user_id) do
    user_id
    |> Vutuv.Social.blocks_involving()
    |> select(
      [b],
      fragment(
        "CASE WHEN ? = ? THEN ? ELSE ? END",
        b.blocker_id,
        type(^user_id, Vutuv.UUIDv7),
        b.blocked_id,
        b.blocker_id
      )
    )
  end

  # Likes on this user's posts. Carries the liked post's id so the notification
  # can link to it. No self-like filter: a member cannot like their own post
  # (enforced in Posts.like_post/2, issue #1030).
  defp like_items(user_id, limit, cursor) do
    # LEFT joins on both actor sides (issue #1336). An inner join to `users` was
    # right while only a member could like, and became a silent filter the day a
    # page could: the row simply never reached the list, so the author was never
    # told. The same shape emptied search, the saved list and the tag pages when
    # `posts.user_id` went nullable.
    from(l in PostLike,
      join: p in assoc(l, :post),
      left_join: liker in assoc(l, :user),
      left_join: page in assoc(l, :organization),
      where: p.user_id == ^user_id,
      order_by: [desc: l.inserted_at, desc: l.id],
      limit: ^limit,
      select: {l.id, l.inserted_at, struct(liker, ^User.listing_fields()), page, p.id}
    )
    |> at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, liker, page, post_id} ->
      event_id("like", id)
      |> actor_item("like", at, liker || page)
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
      event_id("organization_role", id)
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
        id: event_id("moderation", id),
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
        id: event_id("image_rejected", id),
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
        protection_item(event_id("report_protection", id), "severed", at, reported)
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
        protection_item(event_id("report_protection_restored", id), "restored", at, reported)
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
      event_id("handle_change", id)
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
  # "Your Arbeitszeugnis has been reviewed." The one notification here with no
  # actor but the installation itself, and the reason the feature needs one at
  # all: a review takes minutes, longer with a queue in front of it, so the
  # member is explicitly invited to close the page. A notification (and the
  # email beside it) is what makes that invitation honest.
  #
  # Derived straight from the finished check rows — no notification table, so
  # deleting the Zeugnis takes its notification with it. Keyed on
  # `finished_at`, not `inserted_at`, which is why it needs its own cursor
  # clause: `inserted_at` is when the member pressed the button, and a row that
  # waited an hour in the queue would sort into the feed an hour before the
  # news it carries.
  defp reference_check_items(user_id, limit, cursor) do
    from(c in Check,
      join: r in assoc(c, :job_reference),
      where: c.user_id == ^user_id and c.status == "done" and not is_nil(c.finished_at),
      order_by: [desc: c.finished_at, desc: c.id],
      limit: ^limit,
      select: {c.id, c.finished_at, c.job_reference_id, r.title, c.grade_span}
    )
    |> at_or_before_finished(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, reference_id, title, grade} ->
      %{
        id: event_id("reference_check", id),
        kind: "reference_check",
        at: at,
        job_reference_id: reference_id,
        title: title,
        grade: grade
      }
    end)
  end

  defp reference_check_max(user_id) do
    from(c in Check,
      where: c.user_id == ^user_id and c.status == "done" and not is_nil(c.finished_at),
      select: %{ts: max(c.finished_at)}
    )
  end

  defp count_reference_checks(user_id, read_at) do
    query =
      from(c in Check,
        where: c.user_id == ^user_id and c.status == "done" and not is_nil(c.finished_at),
        select: %{count: count()}
      )

    if read_at, do: where(query, [c], c.finished_at > ^read_at), else: query
  end

  defp at_or_before_finished(query, nil), do: query

  defp at_or_before_finished(query, %{at: at}),
    do: where(query, [c], c.finished_at <= ^at)

  defp username_items(user_id, limit, cursor) do
    from(u in User,
      where: u.id == ^user_id and not is_nil(u.welcome_notified_at),
      limit: ^limit,
      select: {u.id, u.welcome_notified_at, u.username}
    )
    |> at_or_before_welcome(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, username} ->
      %{id: event_id("username", id), kind: "username", at: at, username: username}
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

  # The actor half for somebody on **another** network (issue #1069). They have
  # no vutuv profile, so the three local fields are deliberately nil — the row
  # then renders the kind glyph instead of an avatar and does not link into a
  # profile that does not exist — and two remote-only fields carry what a reader
  # actually needs: the `@handle@host` that names which network answered, and
  # the account URL to follow out to.
  #
  # `actor_url` also gives the grouping a stable identity: without it two
  # different strangers who share a display name would fold into one row
  # (`VutuvWeb.NotificationLive.Groups.actor_key/1`).
  defp remote_actor_fields(%Note{} = note) do
    %{
      actor_id: nil,
      actor_name: Note.label(note),
      actor_param: nil,
      actor_avatar: nil,
      actor_handle: Note.display_handle(note),
      actor_url: note.actor_uri
    }
  end

  # A reaction knows no display name (we deliberately never stored one), so the
  # `@handle@host` is both the name and the handle.
  defp remote_actor_fields(%Reaction{} = reaction) do
    handle = Reaction.display_handle(reaction)

    %{
      actor_id: nil,
      actor_name: handle,
      actor_param: nil,
      actor_avatar: nil,
      actor_handle: handle,
      actor_url: reaction.actor_uri
    }
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
      actor_kind: actor_kind(actor),
      actor_name: display_name(actor),
      actor_param: actor_param(actor),
      actor_avatar: actor_avatar(actor)
    }
  end

  # Which sort of actor this is (issue #1336), because `actor_param` alone
  # cannot say: a member's param is their handle and lives at `/handle`, while a
  # page's is a slug that lives under `/organizations/:slug`. Building the link
  # from the param alone would send a reader into the member namespace, at a
  # word somebody else may hold.
  defp actor_kind(%Organization{}), do: "organization"
  defp actor_kind(%User{}), do: "user"
  defp actor_kind(_), do: "user"

  defp actor_id(%User{id: id}), do: id
  defp actor_id(%Organization{id: id}), do: id
  defp actor_id(_), do: nil

  # Each count helper returns a query selecting a single count, so total_count/2
  # can fold all three into one round trip via scalar subqueries.
  defp count_followers(user_id, read_at) do
    from(c in Follow, where: c.followee_id == ^user_id)
    |> join_party(:follower_id, :follower_organization_id)
    |> where([c, u, o], shown_party(u, o))
    |> select([c], %{count: count()})
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
  #
  # `closed_by_other?` is the badge's half of it: a pair is two follow rows,
  # and whoever wrote the later one closed the circle on purpose — telling them
  # about their own click is what put a badge on the bell for something the
  # member had just done. The other side still hears about it, because a
  # follow-back can arrive days after the follow and is real news there. Only
  # the tally asks; the list (`connection_items/3`) and the pager
  # (`notifications_count/2`) keep showing the entry to both sides, the same
  # division of labour `mark_post_seen/2` already draws.
  #
  # It reads the **ids**, not `inserted_at`: the column keeps whole seconds, so
  # a quick follow-back ties there and could not be told apart at all, while a
  # `Vutuv.UUIDv7` carries sub-millisecond ordering bits (the id order this
  # module's keyset cursors already rely on).
  defp count_connections(user_id, read_at, closed_by_other? \\ false) do
    query =
      from(out in Follow,
        join: back in Follow,
        on: back.follower_id == out.followee_id and back.followee_id == out.follower_id,
        where: out.follower_id == ^user_id,
        select: %{count: count()}
      )

    query =
      if closed_by_other?,
        do: where(query, [out, back], back.id > out.id),
        else: query

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

  defp count_replies(user_id, read_at, unread? \\ false) do
    from(r in PostReply,
      join: reply in assoc(r, :post),
      where: r.parent_author_id == ^user_id and reply.user_id != ^user_id,
      select: %{count: count()}
    )
    |> since(read_at)
    |> unless_seen(user_id, unread?)
  end

  defp count_thread_replies(user_id, read_at, unread?) do
    thread_replies(user_id)
    |> select([thread_ref: r], %{count: count()})
    |> since(read_at)
    |> unless_seen(user_id, unread?)
  end

  defp count_mentions(user_id, read_at, unread?) do
    mention_events(user_id)
    |> select([mention: m], %{count: count()})
    |> since(read_at)
    |> unless_seen(user_id, unread?)
  end

  # Drops the events whose subject post the member has already engaged with.
  # All three affected sources key on `post_id` of their first binding — the
  # answer for a reply / thread event, the naming post for a mention — which is
  # exactly what `mark_post_seen/2` writes, so one clause covers them.
  defp unless_seen(query, _user_id, false), do: query

  defp unless_seen(query, user_id, true) do
    seen = from(s in NotificationPostRead, where: s.user_id == ^user_id, select: s.post_id)
    where(query, [event], event.post_id not in subquery(seen))
  end

  # Drops the one event the member acknowledged by clicking its browser
  # notification (`mark_notification_seen/3`). Same division of labour as
  # `unless_seen/3`: only the badge tally asks, the page keeps listing the row.
  #
  # The `:id` shape covers every kind but one, because a count query counts
  # rows of the source table it is named after and that table is its first
  # binding — the assumption `since/2` already makes. The exception is the
  # connection pair, which is two rows and names itself by the later of them.
  # Which shape a kind uses is declared in `kind_specs/3`, so this is applied
  # once in `total_count/4` rather than inside seventeen count queries.
  defp unless_dismissed(query, _user_id, _dismiss, false), do: query
  defp unless_dismissed(query, _user_id, nil, true), do: query

  defp unless_dismissed(query, user_id, {kind, :id}, true),
    do: where(query, [event], event.id not in subquery(dismissed_ids(user_id, kind)))

  defp unless_dismissed(query, user_id, {kind, :later_follow}, true) do
    where(
      query,
      [out, back],
      fragment("GREATEST(?, ?)", out.id, back.id) not in subquery(dismissed_ids(user_id, kind))
    )
  end

  defp dismissed_ids(user_id, kind) do
    from(d in NotificationDismissal,
      where: d.user_id == ^user_id and d.kind == ^kind,
      select: d.source_id
    )
  end

  # No self-like filter: a member cannot like their own post (enforced in
  # Posts.like_post/2, issue #1030).
  defp count_likes(user_id, read_at) do
    from(l in PostLike,
      join: p in assoc(l, :post),
      where: p.user_id == ^user_id,
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
  # An organization is addressed by its slug; `Organizations.canonical_path/1`
  # is what turns that into the page's URL, handle or not.
  defp actor_param(%Organization{slug: slug}), do: slug
  defp actor_param(_), do: nil

  # nil (not the default-placeholder URL) when the actor has no picture, so
  # the notifications page renders its colored kind glyph instead of a grey
  # anonymous image.
  defp actor_avatar(%User{avatar: nil}), do: nil
  # An avatar in AI-moderation limbo renders like none (the kind glyph), not
  # as the grey placeholder display_url would fall back to.
  defp actor_avatar(%User{avatar_moderation: "pending"}), do: nil
  defp actor_avatar(%User{} = user), do: Vutuv.Avatar.display_url(user, :thumb)
  # nil for an organization: the notifications page then draws its coloured kind
  # glyph, which is honest, where a member's avatar helper would not know how to
  # find a page's logo anyway.
  defp actor_avatar(%Organization{}), do: nil
  defp actor_avatar(_), do: nil

  defp display_name(%Organization{} = organization), do: Identity.display_name(organization)

  defp display_name(%User{} = user), do: or_someone(Identity.display_name(user))

  defp display_name(%{first_name: first, last_name: last}) do
    [first, last]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> or_someone()
  end

  defp display_name(_), do: "Someone"

  defp or_someone(""), do: "Someone"
  defp or_someone(name), do: name
end
