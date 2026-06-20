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
  import Vutuv.Moderation.Query, only: [account_hidden_row: 1, account_confirmed_row: 1]
  import Vutuv.SearchText, only: [escape_like: 1, normalize_search: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.Social.Block
  alias Vutuv.Social.Connection
  alias Vutuv.Social.Follow
  alias Vutuv.Social.UserBookmark
  alias Vutuv.Social.UserLike
  alias Vutuv.UUIDv7

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
      actor = follower_struct(follower)

      # A follow-back that completes a mutual follow makes the pair "vernetzt"
      # (connected): announce that meaningful milestone to the followee instead
      # of a second plain "started following you". A first/one-way follow stays
      # the ordinary new-follower event.
      if user_follows_user?(followee_id, follower_id(follower)) do
        Vutuv.Activity.notify_connection(followee_id, actor)
      else
        Vutuv.Activity.notify_new_follower(followee_id, actor)
      end
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

  @doc """
  Flips the mute flag on the caller's own follow and returns the updated
  `%Follow{}`. Like `unfollow!/2` the lookup is scoped to `follower_id`, so a
  caller can only mute a follow they own. Muting is silent (no notification):
  the followee never learns they were muted; the relationship and any mutual
  "vernetzt" status are untouched — only the followee's posts leave the muter's
  feed (`Vutuv.Posts` reads `muted`).
  """
  def toggle_follow_mute!(follower_id, follow_id) do
    follow = Repo.get_by!(Follow, id: follow_id, follower_id: follower_id)

    follow
    |> Follow.changeset(%{muted: not follow.muted})
    |> Repo.update!()
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
        where: account_confirmed_row(u) and not account_hidden_row(u),
        where: c.followee_id == ^user.id,
        select: count(c.id)
      )
    )
  end

  def followee_count(user) do
    Repo.one(
      from(c in Follow,
        join: u in assoc(c, :followee),
        where: account_confirmed_row(u) and not account_hidden_row(u),
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
  The `follower → followee` follow edge as `%{id:, muted?:}`, or `nil` when
  there is none. The profile header needs the id (for the unfollow / mute
  links) and the mute state in one lookup.
  """
  def follow_edge(follower_id, followee_id) do
    Repo.one(
      from(c in Follow,
        where: c.follower_id == ^follower_id and c.followee_id == ^followee_id,
        select: %{id: c.id, muted?: c.muted}
      )
    )
  end

  @doc """
  `follower_id`'s follow edges to each of `followee_ids`, as a map
  `followee_id => %{id:, muted?:}` (missing key = not following). One query for
  a whole page of authors / a follow list, so a per-row mute control never
  queries on its own. Empty map for no follower or no ids.
  """
  def follow_edges(nil, _followee_ids), do: %{}
  def follow_edges(_follower_id, []), do: %{}

  def follow_edges(follower_id, followee_ids) do
    from(c in Follow,
      where: c.follower_id == ^follower_id and c.followee_id in ^followee_ids,
      select: {c.followee_id, %{id: c.id, muted?: c.muted}}
    )
    |> Repo.all()
    |> Map.new()
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
          fr.id == fl.follower_id and account_confirmed_row(fr) and
            not account_hidden_row(fr),
        group_by: fl.followee_id,
        select: %{followee_id: fl.followee_id, count: count()}
      )

    Repo.all(
      from(u in Vutuv.Accounts.User,
        join: fc in subquery(follower_counts),
        on: fc.followee_id == u.id,
        where: account_confirmed_row(u) and not account_hidden_row(u),
        order_by: [desc: fc.count, asc: u.first_name, asc: u.last_name],
        limit: ^limit,
        select: struct(u, ^User.listing_fields())
      )
    )
  end

  # ── Vernetzt = mutual follow (derived) ──
  #
  # There is no separate connection record any more: two people are "vernetzt"
  # (connected) exactly when they follow each other. So there is no request /
  # accept / decline / cooldown — you just follow, and a follow-back makes the
  # pair vernetzt (`do_follow/2` fires the live "you are now connected" event).
  # The read side (`connected?/2`, `connection_count/1`, `list_connections/1`)
  # is derived from `follows`; see those functions further down.

  @doc """
  Cuts every social tie between the two users in one go: both follow edges are
  deleted (a mutual follow is what makes them vernetzt, so dropping both ends
  the connection too). Returns which edges existed -
  `%{follow_a_to_b: bool, follow_b_to_a: bool}`, directions relative to the
  argument order - so the caller (`Vutuv.Moderation`, when a report severs the
  relationship) can record it and a rejected report can restore it.
  Deliberately quiet: no notifications for a protective measure.
  """
  def sever_between(user_id, other_id) do
    {a_to_b, _} =
      Repo.delete_all(
        from(f in Follow, where: f.follower_id == ^user_id and f.followee_id == ^other_id)
      )

    {b_to_a, _} =
      Repo.delete_all(
        from(f in Follow, where: f.follower_id == ^other_id and f.followee_id == ^user_id)
      )

    %{follow_a_to_b: a_to_b > 0, follow_b_to_a: b_to_a > 0}
  end

  @doc """
  Restores the follow edges `sever_between/2` cut, skipping anything the two
  have since rebuilt on their own. `opts`: the `:follow_a_to_b` /
  `:follow_b_to_a` booleans relative to `{user_id, other_id}`. Restoring both
  edges restores the vernetzt status. Quiet like the severing - a restore must
  not fire "started following you" notifications.
  """
  def restore_between(user_id, other_id, opts) do
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
    result =
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

    if match?({:ok, _}, result), do: broadcast_presence_blocks([blocker.id, blocked.id])
    result
  end

  # Tell both members' open shells to refresh their online-dot block filter, so
  # a block/unblock hides (or restores) the pair's dots without a page reload.
  defp broadcast_presence_blocks(user_ids),
    do: Enum.each(user_ids, &Vutuv.Activity.broadcast(&1, :presence_blocks_changed))

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

        broadcast_presence_blocks([blocker.id, blocked.id])
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

  @doc """
  Query of every `Block` row that involves `user_id` (as blocker or blocked) —
  the "either direction" filter, defined once. Shared by `blocked_user_ids/1`
  here and `Vutuv.Posts` feed exclusion.
  """
  def blocks_involving(user_id) do
    from(b in Block, where: b.blocker_id == ^user_id or b.blocked_id == ^user_id)
  end

  @doc """
  Every user id that has a block relationship with `user_id` in either direction
  (members `user_id` blocked + members who blocked `user_id`), as a `MapSet` of
  string ids, excluding `user_id` itself. The shell subtracts this from the
  site-wide online set so a blocked pair never sees each other's online dot.
  """
  def blocked_user_ids(user_id) when is_binary(user_id) do
    blocks_involving(user_id)
    |> select([b], {b.blocker_id, b.blocked_id})
    |> Repo.all()
    |> Enum.flat_map(fn {blocker_id, blocked_id} -> [blocker_id, blocked_id] end)
    |> Enum.reject(&(&1 == user_id))
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  def blocked_user_ids(_user_id), do: MapSet.new()

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

  # ── Liking / bookmarking a person ──
  #
  # The lightweight, **private** save that the post like/bookmark have always
  # had, now for a member too: one row per (actor, target), idempotent toggle,
  # silent (no notification, no public count) and free of any follow/connection
  # prerequisite — you can save a stranger. Refused across a block in either
  # direction (a save is harmless, but enumerating/keeping a blocked member is
  # not), and you cannot save yourself. Every real change broadcasts
  # `{:user_engagement_changed, …}` on the actor's activity topic so an open
  # /likes or /bookmarks page in another tab adds or drops the row live.

  @doc "Bookmarks `target` as `user` (idempotent). `:ok` | `{:error, :self | :blocked}`."
  def bookmark_user(%User{} = user, %User{} = target),
    do: save_user(UserBookmark, :bookmark, user, target)

  @doc "Removes `user`'s bookmark of `target` (idempotent)."
  def unbookmark_user(%User{} = user, %User{} = target),
    do: unsave_user(UserBookmark, :bookmark, user, target)

  @doc "Likes `target` as `user` (idempotent). `:ok` | `{:error, :self | :blocked}`."
  def like_user(%User{} = user, %User{} = target),
    do: save_user(UserLike, :like, user, target)

  @doc "Removes `user`'s like of `target` (idempotent)."
  def unlike_user(%User{} = user, %User{} = target),
    do: unsave_user(UserLike, :like, user, target)

  defp save_user(_schema, _kind, %User{id: id}, %User{id: id}), do: {:error, :self}

  defp save_user(schema, kind, %User{} = user, %User{} = target) do
    if blocked_between?(user.id, target.id) do
      {:error, :blocked}
    else
      now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

      row = %{
        id: UUIDv7.generate(),
        user_id: user.id,
        target_user_id: target.id,
        inserted_at: now,
        updated_at: now
      }

      # Ids are minted in code, so the inserted row count (0 on conflict) is
      # what tells a fresh save from the idempotent repeat.
      case Repo.insert_all(schema, [row],
             on_conflict: :nothing,
             conflict_target: [:user_id, :target_user_id]
           ) do
        {0, _} -> :ok
        {1, _} -> broadcast_user_engagement(kind, user.id, target.id, true)
      end
    end
  end

  defp unsave_user(schema, kind, %User{} = user, %User{} = target) do
    {count, _} =
      Repo.delete_all(
        from(e in schema, where: e.user_id == ^user.id and e.target_user_id == ^target.id)
      )

    if count > 0, do: broadcast_user_engagement(kind, user.id, target.id, false), else: :ok
  end

  defp broadcast_user_engagement(kind, user_id, target_user_id, active?) do
    Vutuv.Activity.broadcast(
      user_id,
      {:user_engagement_changed, %{kind: kind, target_user_id: target_user_id, active?: active?}}
    )

    :ok
  end

  @doc """
  Whether `user` has liked / bookmarked `target` — the two toggle states the
  profile header renders, in one round trip. `%{liked?: bool, bookmarked?:
  bool}`.
  """
  def user_saved_flags(%User{} = user, %User{} = target) do
    Repo.one(
      from(t in User,
        where: t.id == ^target.id,
        select: %{
          liked?:
            fragment(
              "EXISTS (SELECT 1 FROM user_likes l WHERE l.user_id = ? AND l.target_user_id = ?)",
              type(^user.id, UUIDv7),
              t.id
            ),
          bookmarked?:
            fragment(
              "EXISTS (SELECT 1 FROM user_bookmarks b WHERE b.user_id = ? AND b.target_user_id = ?)",
              type(^user.id, UUIDv7),
              t.id
            )
        }
      )
    ) || %{liked?: false, bookmarked?: false}
  end

  @doc """
  One page of the members `user` bookmarked, for the saved-items hub. See
  `saved_users_page/3` for `opts` (`:search`, `:sort`, `:limit`, `:offset`).
  """
  def bookmarked_users_page(%User{} = user, opts \\ []),
    do: saved_users_page(UserBookmark, user, opts)

  @doc "One page of the members `user` liked — see `bookmarked_users_page/2`."
  def liked_users_page(%User{} = user, opts \\ []), do: saved_users_page(UserLike, user, opts)

  # `opts`: `:search` (matches first/last name, @handle and headline,
  # case-insensitive), `:sort` (`:recent` default newest-saved-first | `:oldest`
  # | `:name` alphabetical), `:limit` (default 20) and `:offset`. Saves of a
  # member now blocked (either direction) or hidden by moderation are filtered
  # out, the same gate the connections/followers lists apply. Offset paginated
  # (any sort + a text filter, the cursor would have to encode every order) and
  # returns `%{entries: [%User{}], more?:, next_offset:}` — pass `:offset` back
  # for the next page.
  defp saved_users_page(schema, %User{id: user_id}, opts) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    sort = Keyword.get(opts, :sort, :recent)
    search = opts |> Keyword.get(:search) |> normalize_search()

    rows =
      from(e in schema,
        join: t in User,
        as: :target,
        on: t.id == e.target_user_id,
        where: e.user_id == ^user_id,
        where: account_confirmed_row(t) and not account_hidden_row(t),
        where:
          not exists(
            from(b in Block,
              where:
                (b.blocker_id == ^user_id and b.blocked_id == parent_as(:target).id) or
                  (b.blocker_id == parent_as(:target).id and b.blocked_id == ^user_id)
            )
          ),
        select: t
      )
      |> filter_saved_search(search)
      |> order_saved(sort)
      |> limit(^(limit + 1))
      |> offset(^offset)
      |> Repo.all()

    %{entries: Enum.take(rows, limit), more?: length(rows) > limit, next_offset: offset + limit}
  end

  defp filter_saved_search(query, nil), do: query

  defp filter_saved_search(query, term) do
    pattern = "%" <> escape_like(term) <> "%"

    from([target: t] in query,
      where:
        ilike(t.first_name, ^pattern) or ilike(t.last_name, ^pattern) or
          ilike(t.username, ^pattern) or ilike(t.headline, ^pattern) or
          ilike(fragment("? || ' ' || ?", t.first_name, t.last_name), ^pattern)
    )
  end

  defp order_saved(query, :oldest), do: order_by(query, [e], asc: e.inserted_at, asc: e.id)

  defp order_saved(query, :name),
    do: order_by(query, [target: t], asc: t.first_name, asc: t.last_name, asc: t.id)

  defp order_saved(query, _recent), do: order_by(query, [e], desc: e.inserted_at, desc: e.id)

  defp quiet_follow(follower_id, followee_id) do
    unless user_follows_user?(follower_id, followee_id) do
      Repo.insert!(%Follow{follower_id: follower_id, followee_id: followee_id})
    end
  end

  @doc """
  Whether any severable tie exists between the two: a follow edge in either
  direction. Backs the report form's "this will separate you" warning
  (`Vutuv.Moderation`).
  """
  def tie_between?(id1, id2) do
    user_follows_user?(id1, id2) or user_follows_user?(id2, id1)
  end

  @doc """
  Whether `id1` and `id2` are vernetzt (connected) — i.e. they follow each
  other. There is no separate connection record; mutuality *is* the connection.
  """
  def connected?(id1, id2) do
    user_follows_user?(id1, id2) and user_follows_user?(id2, id1)
  end

  @doc """
  A user's vernetzt list (people they mutually follow) as
  `%{user: other, follow_id: my_follow_id, muted?: bool}`, the pair that
  became mutual most recently first. The other endpoint must be activated and
  not moderation-hidden — a member the platform hid must not stay enumerable
  through someone else's connections page. The owner's own state is deliberately
  not checked: a frozen member still sees their own list through the moderation
  bypass. `follow_id` is the owner's outbound follow, so the page can offer
  "unfollow" (which ends the vernetzt status).
  """
  def list_connections(%User{id: user_id}) do
    mutual_follows_query(user_id)
    |> order_by([out, back], desc: fragment("GREATEST(?, ?)", out.id, back.id))
    |> select([out, _back, o], %{user: o, follow_id: out.id, muted?: out.muted})
    |> Repo.all()
  end

  @doc """
  How many people `user` is vernetzt with (mutual follows) — same visibility
  rule as `list_connections/1`, so the profile count never disagrees with the
  list.
  """
  def connection_count(%User{id: user_id}) do
    mutual_follows_query(user_id)
    |> select([out], count(out.id))
    |> Repo.one()
  end

  # The mutual-follow set for `user_id`: their outbound follow joined to the
  # matching inbound follow, with the *other* party (the followee) joined and
  # gated to activated, non-hidden accounts. One row per vernetzt pair, bound as
  # [out, back, o] (my follow, their follow back, the other user).
  defp mutual_follows_query(user_id) do
    from(out in Follow,
      join: back in Follow,
      on: back.follower_id == out.followee_id and back.followee_id == out.follower_id,
      join: o in User,
      on: o.id == out.followee_id,
      where: out.follower_id == ^user_id,
      where: account_confirmed_row(o) and not account_hidden_row(o)
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

  @doc """
  One-time data migration for the follow/connect simplification: the mutual
  connection request/accept flow is gone, so promote every still-*pending*
  connection request to a follow from the requester to the other party. The
  requester's intent ("I want a relationship with you") survives as a follow,
  and a follow-back now makes the pair vernetzt. Accepted connections already
  carry both follow edges; declined ones held no intent worth keeping.

  Reads the `connections` table schemaless (the live model no longer touches it;
  it is dropped in a later expand/contract deploy), mints v7 ids per the
  chokepoint, and is idempotent — the `(follower, followee)` unique index makes
  the `ON CONFLICT` a no-op for a pair that already follows. Returns the number
  of follows inserted.
  """
  def convert_pending_connections_to_follows do
    now = now()

    rows =
      Repo.all(
        from(c in "connections",
          where: c.status == "pending",
          select: %{
            requester: type(c.requested_by_id, Vutuv.UUIDv7),
            followee:
              type(
                fragment(
                  "CASE WHEN ? = ? THEN ? ELSE ? END",
                  c.requested_by_id,
                  c.user_a_id,
                  c.user_b_id,
                  c.user_a_id
                ),
                Vutuv.UUIDv7
              )
          }
        )
      )

    entries =
      Enum.map(rows, fn r ->
        %{
          id: Vutuv.UUIDv7.generate(),
          follower_id: r.requester,
          followee_id: r.followee,
          inserted_at: now,
          updated_at: now
        }
      end)

    case entries do
      [] ->
        0

      entries ->
        {count, _} =
          Repo.insert_all(Follow, entries,
            on_conflict: :nothing,
            conflict_target: [:follower_id, :followee_id]
          )

        count
    end
  end

  defp now, do: NaiveDateTime.utc_now(:second)
end
