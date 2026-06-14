defmodule Vutuv.Social do
  @moduledoc """
  The Social context. Handles follows (follow/unfollow), the mutual
  connection lifecycle (request/accept/decline), groups, and memberships.

  **Follow vs connection.** A *follow* (`Vutuv.Social.Follow`) is a
  one-directional subscription: follow anyone, no approval, it decides whose
  posts reach your feed. A *connection* (`Vutuv.Social.Connection`) is a
  symmetric, consented relationship: you request it, the other party accepts,
  and acceptance auto-creates a follow in both directions — which either side
  may then drop (`unfollow!/2`) while staying connected.
  """

  import Ecto.Query
  import Vutuv.Moderation.Query, only: [account_hidden: 1, account_hidden_row: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.Social.Block
  alias Vutuv.Social.Connection
  alias Vutuv.Social.Follow

  # ── Follows ──

  @doc """
  Follow a user. `follower` is a `%Vutuv.Accounts.User{}` or an id — callers
  that already hold the session user struct pass it directly, which saves the
  `Repo.get` otherwise needed to build the live new-follower notification.
  """
  def follow(follower, followee_id) do
    if blocked_between?(follower_id(follower), followee_id) do
      {:error, :blocked}
    else
      do_follow(follower, followee_id)
    end
  end

  defp do_follow(follower, followee_id) do
    result =
      %Follow{}
      |> Follow.changeset(%{follower_id: follower_id(follower), followee_id: followee_id})
      |> Repo.insert()

    with {:ok, _follow} <- result do
      # A follow is just a subscription now; the mutual "connection" is its own
      # consented relationship (request/accept), not a side effect of a
      # follow-back. So this only pushes the "started following you" event.
      Vutuv.Activity.notify_new_follower(followee_id, follower_struct(follower))
    end

    result
  end

  defp follower_id(%Vutuv.Accounts.User{id: id}), do: id
  defp follower_id(id), do: id

  defp follower_struct(%Vutuv.Accounts.User{} = user), do: user
  defp follower_struct(id), do: Repo.get(Vutuv.Accounts.User, id)

  @doc """
  Deletes a follow edge. The lookup is scoped to `follower_id`, so a caller can
  only remove their own follows, never an arbitrary one by id.
  """
  def unfollow!(follower_id, follow_id) do
    Repo.get_by!(Follow, id: follow_id, follower_id: follower_id)
    |> Repo.delete!()
  end

  # The public pages only count/show follows from activated accounts (nil
  # covers legacy rows that predate the flag) that moderation has not hidden,
  # matching Follow.latest/2. The gate sits on the counted person only — the
  # other end is the page owner, who may be a frozen member viewing their own
  # lists through the moderation bypass.

  def follower_count(user) do
    Repo.one(
      from(c in Follow,
        join: u in assoc(c, :follower),
        where:
          (is_nil(u.email_confirmed?) or u.email_confirmed? == true) and not account_hidden(u.id),
        where: c.followee_id == ^user.id,
        select: count(c.id)
      )
    )
  end

  def followee_count(user) do
    Repo.one(
      from(c in Follow,
        join: u in assoc(c, :followee),
        where:
          (is_nil(u.email_confirmed?) or u.email_confirmed? == true) and not account_hidden(u.id),
        where: c.follower_id == ^user.id,
        select: count(c.id)
      )
    )
  end

  @doc """
  One page of a user's follow lists for the browse pages: `side` is
  `:followers` (people following `user`) or `:followees` (people `user`
  follows), newest follow first. `params` are the request params understood
  by `Vutuv.Pages.paginate/3`. Returns `%{user: user_with_preload, users:
  [people on this page], total: count}` — the shared engine behind the
  otherwise identical follower/followee index actions.
  """
  def follows_page(%User{} = user, side, params) when side in [:followers, :followees] do
    {total, assoc, person} =
      case side do
        :followers -> {follower_count(user), :inbound_follows, :follower}
        :followees -> {followee_count(user), :outbound_follows, :followee}
      end

    query = Follow.latest(100, person) |> Vutuv.Pages.paginate(params, total)
    user = Repo.preload(user, [{assoc, {query, [person]}}])

    %{
      user: user,
      users: user |> Map.fetch!(assoc) |> Enum.map(&Map.fetch!(&1, person)),
      total: total
    }
  end

  def user_follows_user?(follower_id, followee_id) do
    Repo.exists?(
      from(c in Follow,
        where: c.follower_id == ^follower_id and c.followee_id == ^followee_id
      )
    )
  end

  @doc """
  The id of the `follower → followee` follow edge, or `nil` when there is none.
  Templates use the id to render the unfollow link.
  """
  def follow_id(follower_id, followee_id) do
    Repo.one(
      from(c in Follow,
        where: c.follower_id == ^follower_id and c.followee_id == ^followee_id,
        select: c.id
      )
    )
  end

  @doc """
  The `limit` users with the most followers, ties broken by name. Backs both
  the public listing page and the profile's default "who to follow" rail.

  Applies the same visibility gate as search: unactivated accounts and
  accounts hidden by moderation never surface. Selects only the columns the
  listing rows render (`Vutuv.Accounts.User.listing_fields/0`), so the sort
  does not drag every user column through it.

  Ranks from the (small) `follows` table rather than grouping the whole users
  table, so a member with no visible follower does not appear at all. On the
  real data that is the same top-N as ranking everyone (the most-followed
  members all have followers), but it replaces a full-table group-by with a
  scan of the far smaller follows table.
  """
  def most_followed_users(limit) do
    # Count each followee's *visible* followers, so the ranking matches the
    # follower_count/1 shown on each profile and can't be inflated by
    # mass-registering never-activated follower accounts.
    follower_counts =
      from(fl in Follow,
        join: fr in Vutuv.Accounts.User,
        on:
          fr.id == fl.follower_id and (is_nil(fr.email_confirmed?) or fr.email_confirmed? == true) and
            not account_hidden_row(fr),
        group_by: fl.followee_id,
        select: %{followee_id: fl.followee_id, count: count()}
      )

    Repo.all(
      from(u in Vutuv.Accounts.User,
        join: fc in subquery(follower_counts),
        on: fc.followee_id == u.id,
        where:
          (is_nil(u.email_confirmed?) or u.email_confirmed? == true) and not account_hidden_row(u),
        order_by: [desc: fc.count, asc: u.first_name, asc: u.last_name],
        limit: ^limit,
        select: struct(u, ^User.listing_fields())
      )
    )
  end

  # ── Connections (mutual, consented) ──

  @decline_cooldown_days 14

  @doc "How many days after a decline the original requester must wait to retry."
  def request_cooldown_days, do: @decline_cooldown_days

  @doc """
  Requests a connection from `me` to `other`, or accepts immediately when
  `other` already has a pending request to `me` (both want it).

  Returns `{:ok, %Connection{}}` on a fresh request, a re-sent request, or a
  mutual auto-accept; `{:error, reason}` for `:self`, `:already_connected`,
  `:already_requested`, or `:cooldown` (a decline whose cooldown has not
  elapsed). A request pushes a live "wants to connect" notification; an
  auto-accept notifies the original requester it was accepted.
  """
  def request_connection(%User{id: id}, %User{id: id}), do: {:error, :self}

  def request_connection(%User{} = me, %User{} = other) do
    if blocked_between?(me.id, other.id) do
      {:error, :blocked}
    else
      do_request_connection(me, other)
    end
  end

  defp do_request_connection(%User{} = me, %User{} = other, retried? \\ false) do
    {a_id, b_id} = connection_pair(me.id, other.id)

    case get_connection_by_pair(a_id, b_id) do
      nil ->
        create_request(me, other, a_id, b_id, retried?)

      %Connection{status: "accepted"} ->
        {:error, :already_connected}

      %Connection{status: "pending", requested_by_id: req_id} = connection ->
        # If the other side already asked, this is mutual desire: accept now.
        # Otherwise it is my own outstanding request.
        if req_id == me.id, do: {:error, :already_requested}, else: do_accept(connection, me)

      %Connection{status: "declined"} = connection ->
        resend_request(connection, me, other)
    end
  end

  defp create_request(%User{} = me, %User{} = other, a_id, b_id, retried?) do
    changeset =
      %Connection{user_a_id: a_id, user_b_id: b_id, requested_by_id: me.id}
      |> Connection.changeset(%{status: "pending", status_changed_at: now()})

    case Repo.insert(changeset) do
      {:ok, connection} ->
        Vutuv.Activity.notify_connection_request(other.id, me)
        {:ok, connection}

      {:error, _changeset} when not retried? ->
        # Lost the race against the other party's simultaneous request (the
        # unique pair index only rejects after their row committed):
        # re-dispatch, where the pending-by-them branch accepts it as the
        # mutual desire it is.
        do_request_connection(me, other, true)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Re-requesting after a decline. Only the original requester is rate-limited
  # (the cooldown runs from the decline); the party who *did* the declining may
  # turn around and request freely, since that is a request in the other
  # direction. Either way `requested_by` flips to whoever is re-opening it.
  defp resend_request(%Connection{requested_by_id: req_id} = connection, %User{} = me, other) do
    if req_id == me.id and not cooldown_elapsed?(connection) do
      {:error, :cooldown}
    else
      changeset =
        connection
        |> Connection.changeset(%{status: "pending", status_changed_at: now()})
        |> Ecto.Changeset.put_change(:requested_by_id, me.id)

      with {:ok, connection} <- Repo.update(changeset) do
        Vutuv.Activity.notify_connection_request(other.id, me)
        {:ok, connection}
      end
    end
  end

  @doc """
  Accepts the pending request `connection_id` addressed to `me` — only the
  recipient (not the requester) may accept. Creates the two follow edges in one
  transaction and notifies the requester. `{:ok, connection}` or
  `{:error, :not_found}`.
  """
  def accept_connection(%User{} = me, connection_id) do
    case fetch_pending_for_recipient(me, connection_id) do
      %Connection{} = connection -> do_accept(connection, me)
      nil -> {:error, :not_found}
    end
  end

  # Flips the row to accepted and materializes the bidirectional follow that a
  # connection implies (idempotent: either edge may already exist). `me` is the
  # accepter; the original requester is notified.
  defp do_accept(%Connection{} = connection, %User{} = me) do
    changeset = Connection.changeset(connection, %{status: "accepted", status_changed_at: now()})

    result =
      Repo.transaction(fn ->
        case Repo.update(changeset) do
          {:ok, accepted} ->
            ensure_follow!(accepted.user_a_id, accepted.user_b_id)
            ensure_follow!(accepted.user_b_id, accepted.user_a_id)
            accepted

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, accepted} <- result do
      Vutuv.Activity.notify_connection_accepted(accepted.requested_by_id, me)
      {:ok, accepted}
    end
  end

  @doc """
  Declines the pending request `connection_id` addressed to `me`. Silent: the
  requester is not notified, and the cooldown lets them retry later.
  `{:ok, connection}` or `{:error, :not_found}`.
  """
  def decline_connection(%User{} = me, connection_id) do
    case fetch_pending_for_recipient(me, connection_id) do
      %Connection{} = connection ->
        connection
        |> Connection.changeset(%{status: "declined", status_changed_at: now()})
        |> Repo.update()
        # The decliner's own pending-request notification is gone; nudge only
        # them. Stays silent toward the requester (`me` is the recipient).
        |> broadcast_notifications_changed([me.id])

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Removes the connection `connection_id` as long as `me` is one of its parties:
  disconnecting (accepted), withdrawing an outgoing request (pending), or
  clearing a declined record. The auto-created follow edges are left intact —
  unfollow separately. `{:ok, connection}` or `{:error, :not_found}`.
  """
  def remove_connection(%User{} = me, connection_id) do
    case fetch_for_party(me, connection_id) do
      %Connection{} = connection ->
        connection
        |> Repo.delete()
        # Withdraw drops the recipient's request badge; disconnect drops both
        # parties' accepted-connection count. Nudge both and let each shell
        # recompute (a no-op for whoever's count didn't change).
        |> broadcast_notifications_changed([connection.user_a_id, connection.user_b_id])

      nil ->
        {:error, :not_found}
    end
  end

  # On a silent change to the unread set (a withdrawn or declined pending
  # request, a disconnect), nudge the affected parties' shells to recompute the
  # notification badge. No notification is pushed, so without this the badge
  # would stay stale until a reload (issue #782).
  defp broadcast_notifications_changed({:ok, _} = result, user_ids) do
    Enum.each(user_ids, &Vutuv.Activity.mark_notifications_changed/1)
    result
  end

  defp broadcast_notifications_changed(result, _user_ids), do: result

  @doc """
  Cuts every social tie between the two users in one go: the connection row
  (any status) and both follow edges are deleted. Returns what existed -
  `%{connection: %Connection{} | nil, follow_a_to_b: bool, follow_b_to_a:
  bool}`, directions relative to the argument order - so the caller
  (`Vutuv.Moderation`, when a report severs the relationship) can record it
  and a rejected report can restore it. Deliberately quiet: no notifications
  for a protective measure.
  """
  def sever_between(user_id, other_id) do
    {a_id, b_id} = connection_pair(user_id, other_id)
    connection = get_connection_by_pair(a_id, b_id)
    if connection, do: Repo.delete!(connection)

    {a_to_b, _} =
      Repo.delete_all(
        from(f in Follow, where: f.follower_id == ^user_id and f.followee_id == ^other_id)
      )

    {b_to_a, _} =
      Repo.delete_all(
        from(f in Follow, where: f.follower_id == ^other_id and f.followee_id == ^user_id)
      )

    %{connection: connection, follow_a_to_b: a_to_b > 0, follow_b_to_a: b_to_a > 0}
  end

  @doc """
  Restores ties `sever_between/2` cut, skipping anything the two have since
  rebuilt on their own. `opts`: `:connection_status` plus
  `:connection_requested_by_id` (nil status = there was no connection), and
  the `:follow_a_to_b` / `:follow_b_to_a` booleans relative to
  `{user_id, other_id}`. Quiet like the severing - a restore must not fire
  "started following you" notifications.
  """
  def restore_between(user_id, other_id, opts) do
    if status = opts[:connection_status] do
      {a_id, b_id} = connection_pair(user_id, other_id)

      unless get_connection_by_pair(a_id, b_id) do
        Repo.insert!(%Connection{
          user_a_id: a_id,
          user_b_id: b_id,
          requested_by_id: opts[:connection_requested_by_id],
          status: status,
          status_changed_at: NaiveDateTime.utc_now(:second)
        })
      end
    end

    if opts[:follow_a_to_b], do: quiet_follow(user_id, other_id)
    if opts[:follow_b_to_a], do: quiet_follow(other_id, user_id)
    :ok
  end

  # ── Blocks ──

  @doc """
  Blocks `blocked`: severs follows and connection both ways
  (`sever_between/2`), freezes the 1:1 conversation, and from then on
  `blocked_between?/2` makes every interaction chokepoint refuse in **both**
  directions — follow, connect, open/continue a conversation, reply, like,
  repost — while reading stays untouched (public content is public; the
  profile and posts pages do not change).

  Quiet by design: no notification fires and the blocked party only ever
  sees the same generic refusals a decline or freeze produces. Idempotent.
  Unblocking lifts the enforcement but restores nothing — deliberately
  unlike a rejected moderation report, which puts severed ties back.
  """
  def block_user(%User{id: id}, %User{id: id}), do: {:error, :self}

  def block_user(%User{} = blocker, %User{} = blocked) do
    case get_block(blocker.id, blocked.id) do
      %Block{} = block ->
        {:ok, block}

      nil ->
        case insert_block(blocker.id, blocked.id) do
          # Lost the race against a concurrent identical block: the winner's
          # row is committed (the unique index only rejects after the other
          # transaction completed), so idempotency means returning it.
          {:error, :raced} -> {:ok, get_block(blocker.id, blocked.id)}
          result -> result
        end
    end
  end

  defp insert_block(blocker_id, blocked_id) do
    Repo.transaction(fn ->
      sever_between(blocker_id, blocked_id)
      # Remember the conversation THIS block froze (nil when none, or
      # when a report already froze it) so unblock thaws only its own.
      conversation = Vutuv.Chat.freeze_conversation_between(blocker_id, blocked_id)

      %Block{
        blocker_id: blocker_id,
        blocked_id: blocked_id,
        conversation_id: conversation && conversation.id
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:blocked_id,
        name: :blocks_blocker_id_blocked_id_index
      )
      |> Repo.insert()
      |> case do
        {:ok, block} -> block
        {:error, _changeset} -> Repo.rollback(:raced)
      end
    end)
  end

  @doc "Removes `blocker`'s block on `blocked` (no-op without one)."
  def unblock_user(%User{} = blocker, %User{} = blocked) do
    case get_block(blocker.id, blocked.id) do
      nil ->
        :ok

      %Block{} = block ->
        {:ok, _} =
          Repo.transaction(fn ->
            Repo.delete!(block)
            maybe_unfreeze_conversation(block)
          end)

        :ok
    end
  end

  # Thaw the conversation this block froze - but only when nothing else
  # still separates the pair: the reverse block, or an active moderation
  # severance from a report (whose rejected/upheld ruling owns that freeze).
  defp maybe_unfreeze_conversation(%Block{conversation_id: nil}), do: :ok

  defp maybe_unfreeze_conversation(%Block{} = block) do
    unless blocked_between?(block.blocker_id, block.blocked_id) or
             Vutuv.Moderation.active_severance_between?(block.blocker_id, block.blocked_id) do
      conversation = Repo.get(Vutuv.Chat.Conversation, block.conversation_id)

      if conversation && conversation.frozen_at,
        do: Vutuv.Chat.unfreeze_conversation(conversation)
    end

    :ok
  end

  @doc """
  Hands freeze-ownership of the pair's frozen 1:1 conversation to the block(s)
  standing between them — used when a moderation report that froze the
  conversation is rejected while a block exists: the report releases the
  freeze, but the block must keep the conversation frozen and thaw it on
  unblock. The conversation is looked up fresh (not taken from the rejected
  severance, whose recorded id is nil for any report that wasn't the first to
  freeze), so the handover is robust across multiple cases. Only fills a block
  whose `conversation_id` is still nil, so it never clobbers a block's own
  freeze.
  """
  def adopt_conversation_freeze(a_id, b_id) do
    case Vutuv.Chat.frozen_conversation_id_between(a_id, b_id) do
      nil ->
        :ok

      conversation_id ->
        from(b in Block,
          where:
            is_nil(b.conversation_id) and
              ((b.blocker_id == ^a_id and b.blocked_id == ^b_id) or
                 (b.blocker_id == ^b_id and b.blocked_id == ^a_id))
        )
        |> Repo.update_all(set: [conversation_id: conversation_id])

        :ok
    end
  end

  def get_block(blocker_id, blocked_id),
    do: Repo.get_by(Block, blocker_id: blocker_id, blocked_id: blocked_id)

  @doc "The current user's own block row by id - the only way to unblock by id."
  def get_block!(%User{id: blocker_id}, block_id),
    do: Repo.get_by!(Block, id: block_id, blocker_id: blocker_id)

  @doc "Whether a block exists in either direction between the two."
  def blocked_between?(a_id, b_id) when is_binary(a_id) and is_binary(b_id) do
    Repo.exists?(
      from(b in Block,
        where:
          (b.blocker_id == ^a_id and b.blocked_id == ^b_id) or
            (b.blocker_id == ^b_id and b.blocked_id == ^a_id)
      )
    )
  end

  def blocked_between?(_a_id, _b_id), do: false

  @doc "The members `user` blocked, newest first, `:blocked` preloaded."
  def list_blocked(%User{} = user) do
    from(b in Block,
      where: b.blocker_id == ^user.id,
      join: u in assoc(b, :blocked),
      order_by: [desc: b.id],
      preload: [blocked: u]
    )
    |> Repo.all()
  end

  defp quiet_follow(follower_id, followee_id) do
    unless user_follows_user?(follower_id, followee_id) do
      Repo.insert!(%Follow{follower_id: follower_id, followee_id: followee_id})
    end
  end

  @doc """
  Whether any severable tie exists between the two: a connection row (any
  status) or a follow edge in either direction. Backs the report form's
  "this will separate you" warning (`Vutuv.Moderation`).
  """
  def tie_between?(id1, id2) do
    {a_id, b_id} = connection_pair(id1, id2)

    get_connection_by_pair(a_id, b_id) != nil or
      user_follows_user?(id1, id2) or
      user_follows_user?(id2, id1)
  end

  @doc "Whether `id1` and `id2` have an accepted connection."
  def connected?(id1, id2) do
    {a_id, b_id} = connection_pair(id1, id2)

    Repo.exists?(
      from(c in Connection,
        where: c.user_a_id == ^a_id and c.user_b_id == ^b_id and c.status == "accepted"
      )
    )
  end

  @doc """
  The connection situation between `me` and `other`, for the profile control:
  `%{status: state, connection: conn | nil}` where state is `:none`,
  `:pending_sent` (I asked), `:pending_received` (they asked — show
  accept/decline), `:accepted`, or `:declined` (my spent request, awaiting the
  cooldown). When *I* declined *them*, their row reads `:none` to me, so I can
  open a fresh request in the other direction.
  """
  def connection_state(%User{id: me_id}, %User{id: other_id}) do
    {a_id, b_id} = connection_pair(me_id, other_id)

    case get_connection_by_pair(a_id, b_id) do
      nil ->
        %{status: :none, connection: nil}

      %Connection{status: "accepted"} = c ->
        %{status: :accepted, connection: c}

      %Connection{status: "pending", requested_by_id: ^me_id} = c ->
        %{status: :pending_sent, connection: c}

      %Connection{status: "pending"} = c ->
        %{status: :pending_received, connection: c}

      %Connection{status: "declined", requested_by_id: ^me_id} = c ->
        %{status: :declined, connection: c}

      %Connection{status: "declined"} = c ->
        %{status: :none, connection: c}
    end
  end

  @doc """
  Accepted connections of `user` as `%{connection:, user: other}`, newest
  first. Connections whose other endpoint is unactivated or hidden by
  moderation are excluded — a member the platform hid must not stay
  enumerable through someone else's connections page. The owner's own state
  is deliberately not checked: a frozen member still sees their own list
  through the moderation bypass.
  """
  def list_connections(%User{id: user_id}) do
    accepted_visible_connections(user_id)
    |> order_by([c], desc: c.status_changed_at, desc: c.id)
    |> Repo.all()
    |> with_other_user(user_id)
  end

  defp accepted_visible_connections(user_id) do
    from(c in Connection,
      where: c.status == "accepted",
      where: c.user_a_id == ^user_id or c.user_b_id == ^user_id
    )
    |> with_visible_other(user_id)
  end

  # Joins the connection's *other* endpoint and keeps only rows whose other
  # party is activated and not moderation-hidden — so request/connection lists
  # never show (or link to) a member the platform has hidden, matching the
  # counts. The viewer's own state is intentionally not checked.
  defp with_visible_other(query, user_id) do
    from(c in query,
      join: o in User,
      on:
        o.id ==
          fragment(
            "CASE WHEN ? = ? THEN ? ELSE ? END",
            c.user_a_id,
            type(^user_id, Vutuv.UUIDv7),
            c.user_b_id,
            c.user_a_id
          ),
      where:
        (is_nil(o.email_confirmed?) or o.email_confirmed? == true) and not account_hidden(o.id)
    )
  end

  @doc "Pending requests addressed to `user` (someone else asked), newest first."
  def list_incoming_requests(%User{id: user_id}) do
    from(c in Connection,
      where: c.status == "pending" and c.requested_by_id != ^user_id,
      where: c.user_a_id == ^user_id or c.user_b_id == ^user_id,
      order_by: [desc: c.status_changed_at, desc: c.id]
    )
    |> with_visible_other(user_id)
    |> Repo.all()
    |> with_other_user(user_id)
  end

  @doc "Pending requests `user` sent that are still awaiting an answer, newest first."
  def list_outgoing_requests(%User{id: user_id}) do
    from(c in Connection,
      where: c.status == "pending" and c.requested_by_id == ^user_id,
      order_by: [desc: c.status_changed_at, desc: c.id]
    )
    |> with_visible_other(user_id)
    |> Repo.all()
    |> with_other_user(user_id)
  end

  @doc """
  How many accepted connections `user` has — same visibility rule as
  `list_connections/1`, so the profile count never disagrees with the list.
  """
  def connection_count(%User{id: user_id}) do
    accepted_visible_connections(user_id)
    |> select([c], count(c.id))
    |> Repo.one()
  end

  @doc """
  One-time backfill (legacy data migration): promote every existing mutual
  follow (A↔B both directions) to an accepted `Connection`. The pair is stored
  canonically and deduped; `requested_by` is the earlier follower and
  `status_changed_at` the later of the two follow times — the moment the
  relationship effectively became mutual. Idempotent (existing connections are
  skipped). Returns the number of connections inserted.
  """
  def backfill_connections_from_mutual_follows do
    now = now()

    rows =
      Repo.all(
        from(f1 in Follow,
          join: f2 in Follow,
          on: f2.follower_id == f1.followee_id and f2.followee_id == f1.follower_id,
          # follower < followee keeps exactly one row per mutual pair (the
          # canonical orientation) and drops the reciprocal duplicate.
          where: f1.follower_id < f1.followee_id,
          select: %{
            a: f1.follower_id,
            b: f1.followee_id,
            # Cast the fragment outputs so they load as a UUID v7 string and a
            # NaiveDateTime — otherwise they come back as raw Postgrex values
            # that insert_all cannot dump back through the schema types.
            requested_by:
              type(
                fragment(
                  "CASE WHEN ? <= ? THEN ? ELSE ? END",
                  f1.inserted_at,
                  f2.inserted_at,
                  f1.follower_id,
                  f2.follower_id
                ),
                Vutuv.UUIDv7
              ),
            changed_at:
              type(fragment("GREATEST(?, ?)", f1.inserted_at, f2.inserted_at), :naive_datetime)
          }
        )
      )

    entries =
      Enum.map(rows, fn r ->
        %{
          id: Vutuv.UUIDv7.generate(),
          user_a_id: r.a,
          user_b_id: r.b,
          requested_by_id: r.requested_by,
          status: "accepted",
          status_changed_at: r.changed_at,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(Connection, entries,
        on_conflict: :nothing,
        conflict_target: [:user_a_id, :user_b_id]
      )

    count
  end

  defp with_other_user(connections, user_id) do
    connections
    |> Repo.preload([:user_a, :user_b])
    |> Enum.map(fn c ->
      other = if c.user_a_id == user_id, do: c.user_b, else: c.user_a
      %{connection: c, user: other}
    end)
  end

  defp fetch_pending_for_recipient(%User{id: me_id}, connection_id) do
    case Vutuv.UUIDv7.cast_or_nil(connection_id) do
      nil ->
        nil

      id ->
        Repo.one(
          from(c in Connection,
            where: c.id == ^id and c.status == "pending" and c.requested_by_id != ^me_id,
            where: c.user_a_id == ^me_id or c.user_b_id == ^me_id
          )
        )
    end
  end

  defp fetch_for_party(%User{id: me_id}, connection_id) do
    case Vutuv.UUIDv7.cast_or_nil(connection_id) do
      nil ->
        nil

      id ->
        Repo.one(
          from(c in Connection,
            where: c.id == ^id,
            where: c.user_a_id == ^me_id or c.user_b_id == ^me_id
          )
        )
    end
  end

  # Sorted pair: smaller id first, matching the DB sorted_pair check (uuid byte
  # order equals canonical lowercase-hex string order, so a plain `<` agrees).
  defp connection_pair(id1, id2) when id1 < id2, do: {id1, id2}
  defp connection_pair(id1, id2), do: {id2, id1}

  defp get_connection_by_pair(a_id, b_id) do
    Repo.get_by(Connection, user_a_id: a_id, user_b_id: b_id)
  end

  defp cooldown_elapsed?(%Connection{status_changed_at: nil}), do: true

  defp cooldown_elapsed?(%Connection{status_changed_at: at}) do
    cutoff = NaiveDateTime.add(now(), -@decline_cooldown_days * 24 * 3600)
    NaiveDateTime.compare(at, cutoff) != :gt
  end

  # Materializes one follow edge if it is not already there (UUID v7 id minted
  # in code per the chokepoint; the unique (follower, followee) index makes the
  # ON CONFLICT a no-op for an existing edge).
  defp ensure_follow!(follower_id, followee_id) do
    now = now()

    Repo.insert_all(
      Follow,
      [
        %{
          id: Vutuv.UUIDv7.generate(),
          follower_id: follower_id,
          followee_id: followee_id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:follower_id, :followee_id]
    )
  end

  defp now, do: NaiveDateTime.utc_now(:second)
end
