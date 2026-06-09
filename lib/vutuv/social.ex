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

  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.Social.Connection
  alias Vutuv.Social.Follow
  alias Vutuv.Social.Group
  alias Vutuv.Social.Membership

  # ── Follows ──

  @doc """
  Follow a user. `follower` is a `%Vutuv.Accounts.User{}` or an id — callers
  that already hold the session user struct pass it directly, which saves the
  `Repo.get` otherwise needed to build the live new-follower notification.
  """
  def follow(follower, followee_id) do
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
  # covers legacy rows that predate the flag), matching Follow.latest/1.

  def follower_count(user) do
    Repo.one(
      from(c in Follow,
        join: u in assoc(c, :follower),
        where: (is_nil(u.activated?) or u.activated? == true) and c.followee_id == ^user.id,
        select: count(c.id)
      )
    )
  end

  def followee_count(user) do
    Repo.one(
      from(c in Follow,
        join: u in assoc(c, :followee),
        where: (is_nil(u.activated?) or u.activated? == true) and c.follower_id == ^user.id,
        select: count(c.id)
      )
    )
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
  """
  def most_followed_users(limit) do
    Repo.all(
      from(u in Vutuv.Accounts.User,
        left_join: f in assoc(u, :followers),
        group_by: u.id,
        order_by: [fragment("count(?) DESC", f.id), u.first_name, u.last_name],
        limit: ^limit
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
    {a_id, b_id} = connection_pair(me.id, other.id)

    case get_connection_by_pair(a_id, b_id) do
      nil ->
        create_request(me, other, a_id, b_id)

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

  defp create_request(%User{} = me, %User{} = other, a_id, b_id) do
    changeset =
      %Connection{user_a_id: a_id, user_b_id: b_id, requested_by_id: me.id}
      |> Connection.changeset(%{status: "pending", status_changed_at: now()})

    with {:ok, connection} <- Repo.insert(changeset) do
      Vutuv.Activity.notify_connection_request(other.id, me)
      {:ok, connection}
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
      %Connection{} = connection -> Repo.delete(connection)
      nil -> {:error, :not_found}
    end
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

  @doc "Accepted connections of `user` as `%{connection:, user: other}`, newest first."
  def list_connections(%User{id: user_id}) do
    from(c in Connection,
      where: c.status == "accepted",
      where: c.user_a_id == ^user_id or c.user_b_id == ^user_id,
      order_by: [desc: c.status_changed_at, desc: c.id]
    )
    |> Repo.all()
    |> with_other_user(user_id)
  end

  @doc "Pending requests addressed to `user` (someone else asked), newest first."
  def list_incoming_requests(%User{id: user_id}) do
    from(c in Connection,
      where: c.status == "pending" and c.requested_by_id != ^user_id,
      where: c.user_a_id == ^user_id or c.user_b_id == ^user_id,
      order_by: [desc: c.status_changed_at, desc: c.id]
    )
    |> Repo.all()
    |> with_other_user(user_id)
  end

  @doc "Pending requests `user` sent that are still awaiting an answer, newest first."
  def list_outgoing_requests(%User{id: user_id}) do
    from(c in Connection,
      where: c.status == "pending" and c.requested_by_id == ^user_id,
      order_by: [desc: c.status_changed_at, desc: c.id]
    )
    |> Repo.all()
    |> with_other_user(user_id)
  end

  @doc "How many accepted connections `user` has."
  def connection_count(%User{id: user_id}) do
    Repo.one(
      from(c in Connection,
        where: c.status == "accepted",
        where: c.user_a_id == ^user_id or c.user_b_id == ^user_id,
        select: count(c.id)
      )
    )
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
    with id when not is_nil(id) <- Vutuv.UUIDv7.cast_or_nil(connection_id) do
      Repo.one(
        from(c in Connection,
          where: c.id == ^id and c.status == "pending" and c.requested_by_id != ^me_id,
          where: c.user_a_id == ^me_id or c.user_b_id == ^me_id
        )
      )
    else
      _ -> nil
    end
  end

  defp fetch_for_party(%User{id: me_id}, connection_id) do
    with id when not is_nil(id) <- Vutuv.UUIDv7.cast_or_nil(connection_id) do
      Repo.one(
        from(c in Connection,
          where: c.id == ^id,
          where: c.user_a_id == ^me_id or c.user_b_id == ^me_id
        )
      )
    else
      _ -> nil
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

  # ── Groups ──

  def list_groups(user) do
    Repo.all(Ecto.assoc(user, :groups))
  end

  def create_group(user, attrs) do
    user
    |> Ecto.build_assoc(:groups)
    |> Group.changeset(attrs)
    |> Repo.insert()
  end

  def update_group(%Group{} = group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a group — unless posts deny it. `post_denials.group_id` is
  RESTRICT on purpose: silently dropping a denial would widen the audience
  of old posts, so the deletion fails with a changeset error instead and the
  UI tells the user to update those posts first.
  """
  def delete_group(%Group{} = group) do
    group
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: :post_denials_group_id_fkey,
      message: "this group limits the audience of existing posts"
    )
    |> Repo.delete()
  end

  @doc """
  The user's groups with their member counts, for the composer's audience
  sheet (`[{group, member_count}]`, sorted by name).
  """
  def groups_with_member_counts(user) do
    Repo.all(
      from(g in Group,
        where: g.user_id == ^user.id,
        left_join: m in assoc(g, :memberships),
        group_by: g.id,
        order_by: g.name,
        select: {g, count(m.id)}
      )
    )
  end

  # ── Memberships ──

  @doc """
  Fetches a membership scoped to `follow`, so a caller can only reach
  memberships of a follow edge they actually own.
  """
  def get_membership!(%Follow{} = follow, id) do
    Repo.get!(Ecto.assoc(follow, :memberships), id)
  end

  def create_membership(%Follow{} = follow, attrs) do
    follow
    |> Ecto.build_assoc(:memberships)
    |> Membership.changeset(attrs)
    |> Repo.insert()
  end

  def delete_membership!(%Membership{} = membership), do: Repo.delete!(membership)
end
