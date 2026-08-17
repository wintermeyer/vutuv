defmodule Vutuv.Social do
  @moduledoc """
  The Social context. Handles follows (follow/unfollow/mute), blocks, the
  "vernetzt" (connected) relationship, and the user search/listing queries.

  **Follow is the only relationship.** A *follow* (`Vutuv.Social.Follow`) is a
  one-directional subscription: follow anyone, no approval, it decides whose
  posts reach your feed. Two people are *connected* ("vernetzt") exactly when
  they follow each other; it is derived from the two follow edges
  (`connected?/2`), never stored as a separate record.
  """

  import Ecto.Query
  import Vutuv.Moderation.Query, only: [account_hidden_row: 1, account_confirmed_row: 1]
  import Vutuv.SearchText, only: [contains: 1, normalize_search: 1, name_ilike: 3]

  alias Vutuv.AccountEvents
  alias Vutuv.Accounts.User
  alias Vutuv.Organizations.Organization
  alias Vutuv.Pages
  alias Vutuv.Repo
  alias Vutuv.Social.Block
  alias Vutuv.Social.Follow
  alias Vutuv.Social.PopularUsers
  alias Vutuv.Social.UserBookmark
  alias Vutuv.Social.UserLike
  alias Vutuv.UUIDv7

  # The two halves of "this follow names somebody who may still be shown", as
  # macros so both the count and the list read the same rule. A page is gated
  # exactly like `Organizations.public_visible?/1`: active AND not frozen — the
  # frozen half is easy to forget, because `status` stays "active" through a
  # freeze.
  defmacrop visible_member(u) do
    quote do
      not is_nil(unquote(u).id) and account_confirmed_row(unquote(u)) and
        not account_hidden_row(unquote(u))
    end
  end

  defmacrop visible_page(o) do
    quote do
      not is_nil(unquote(o).id) and unquote(o).status == "active" and is_nil(unquote(o).frozen_at)
    end
  end

  # ── Follows ──

  @doc """
  Follow a user. `follower` is a `%Vutuv.Accounts.User{}` or an id — callers
  that already hold the session user struct pass it directly, which saves the
  `Repo.get` otherwise needed to build the live new-follower notification.
  """
  def follow(follower, followee_id) do
    # Cast the (possibly client-supplied) target id up front: a non-UUID string
    # would otherwise raise Ecto.Query.CastError deep in blocked_between?.
    case Vutuv.UUIDv7.cast_or_nil(followee_id) do
      nil ->
        {:error, :invalid}

      followee_id ->
        if blocked_between?(follower_id(follower), followee_id) do
          {:error, :blocked}
        else
          do_follow(follower, followee_id)
        end
    end
  end

  defp do_follow(follower, followee_id) do
    follower_id = follower_id(follower)

    result =
      %Follow{}
      |> Follow.changeset(%{follower_id: follower_id, followee_id: followee_id})
      |> Repo.insert()

    with {:ok, _follow} <- result do
      actor = follower_struct(follower)

      # A follow-back that completes a mutual follow makes the pair "vernetzt"
      # (connected): announce that meaningful milestone to the followee instead
      # of a second plain "started following you". A first/one-way follow stays
      # the ordinary new-follower event.
      if user_follows_user?(followee_id, follower_id) do
        Vutuv.Activity.notify_connection(followee_id, actor)
      else
        Vutuv.Activity.notify_new_follower(followee_id, actor)
      end

      # Bump the live counts on both members' open profiles (follower / following
      # / connection, and the viewer's follow-state pill).
      broadcast_social_graph_changed([follower_id, followee_id])
    end

    result
  end

  @doc """
  Follow an organization page (issue #1336), so its posts land in `follower`'s
  feed. Idempotent: following twice returns the edge that already exists rather
  than an error, because the control is a toggle and a double click must not
  read as a failure.

  There is no notification and no block check, and both are deliberate: a page
  has no inbox to be told (that is the rest of #1336), and blocks are a
  relationship between two people.
  """
  def follow_organization(follower, %Organization{} = organization) do
    follower_id = follower_id(follower)

    result =
      %Follow{}
      |> Follow.organization_changeset(%{
        follower_id: follower_id,
        followee_organization_id: organization.id
      })
      |> Repo.insert()

    case result do
      {:ok, _follow} = ok ->
        broadcast_social_graph_changed([follower_id])
        ok

      {:error, _changeset} ->
        case organization_follow(follower_id, organization.id) do
          %Follow{} = existing -> {:ok, existing}
          nil -> result
        end
    end
  end

  @doc "Drops `follower`'s follow of `organization`. Idempotent."
  def unfollow_organization(follower, %Organization{} = organization) do
    follower_id = follower_id(follower)

    case organization_follow(follower_id, organization.id) do
      %Follow{} = follow ->
        Repo.delete!(follow)
        broadcast_social_graph_changed([follower_id])
        :ok

      nil ->
        :ok
    end
  end

  @doc "The follower's edge to `organization_id`, or nil."
  def organization_follow(follower_id, organization_id) do
    Repo.get_by(Follow, follower_id: follower_id, followee_organization_id: organization_id)
  end

  @doc "Whether `follower` follows `organization`."
  def follows_organization?(nil, _organization), do: false

  def follows_organization?(follower, %Organization{id: organization_id}),
    do: organization_follow(follower_id(follower), organization_id) != nil

  @doc """
  How many members follow `organization`.

  Gated exactly like the follower rows on the page's activity list
  (`Organizations.activity_follows/3`), which is the member-side rule too: a
  count and the list it stands for must agree. Without the join this counted
  every row — unconfirmed and moderation-hidden members, and now that the column
  exists, a page following a page — so the figure above the page could promise
  followers it would never name.
  """
  def organization_follower_count(%Organization{id: id}) do
    Repo.aggregate(
      from(f in Follow,
        join: u in User,
        on: u.id == f.follower_id,
        where: f.followee_organization_id == ^id,
        where: account_confirmed_row(u) and not account_hidden_row(u)
      ),
      :count
    )
  end

  @doc """
  A page follows a member or another page (issue #1336) — the writer for the
  column that shipped in v7.248.1. Idempotent, like its member twin.

  No notification and no block check, for the same reasons `follow_organization/2`
  has neither: a page has no inbox, and a block is between two people.
  """
  def follow_as_organization(%Organization{} = page, followee) do
    {column, followee_id} = followee_column(followee)

    result =
      %Follow{}
      |> Follow.organization_follower_changeset(column, %{
        :follower_organization_id => page.id,
        column => followee_id
      })
      |> Repo.insert()

    case result do
      {:ok, _follow} = ok ->
        # A member learns that a page followed them, the same way they learn
        # about a person (issue #1336). A page has no inbox, so the mirror case
        # (following a page) still notifies nobody.
        notify_new_page_follower(page, followee)

        # The followee's own profile recomputes: a page counts as a follower.
        broadcast_social_graph_changed([followee_id])
        ok

      {:error, _changeset} ->
        case organization_follow_edge(page.id, column, followee_id) do
          %Follow{} = existing -> {:ok, existing}
          nil -> result
        end
    end
  end

  @doc "Drops a page's follow of `followee`. Idempotent."
  def unfollow_as_organization(%Organization{} = page, followee) do
    {column, followee_id} = followee_column(followee)

    case organization_follow_edge(page.id, column, followee_id) do
      %Follow{} = follow ->
        Repo.delete!(follow)
        broadcast_social_graph_changed([followee_id])
        :ok

      nil ->
        :ok
    end
  end

  @doc """
  Drops one of `page`'s own follow edges by id. Idempotent, and scoped to the
  page: an id belonging to somebody else's edge removes nothing, so the client
  cannot be trusted with more than a hint about which row it meant.
  """
  def unfollow_edge_as_organization(%Organization{id: page_id}, follow_id) do
    case Vutuv.UUIDv7.cast_or_nil(follow_id) do
      nil ->
        0

      follow_id ->
        {count, _} =
          from(f in Follow,
            where: f.id == ^follow_id and f.follower_organization_id == ^page_id
          )
          |> Repo.delete_all()

        count
    end
  end

  @doc "Whether `page` follows `followee`."
  def organization_follows?(%Organization{} = page, followee) do
    {column, followee_id} = followee_column(followee)
    organization_follow_edge(page.id, column, followee_id) != nil
  end

  @doc "The page's follow edge to a local member or organization, or nil."
  def organization_follow_as_organization(%Organization{} = page, followee) do
    {column, followee_id} = followee_column(followee)
    organization_follow_edge(page.id, column, followee_id)
  end

  defp notify_new_page_follower(%Organization{} = page, %User{id: id}),
    do: Vutuv.Activity.notify_new_follower(id, page)

  defp notify_new_page_follower(_page, _followee), do: :ok

  defp followee_column(%Organization{id: id}), do: {:followee_organization_id, id}
  defp followee_column(%User{id: id}), do: {:followee_id, id}

  defp organization_follow_edge(page_id, column, followee_id) do
    Repo.get_by(Follow, [{:follower_organization_id, page_id}, {column, followee_id}])
  end

  @doc """
  What `page` follows, newest first, as `[{follow_id, member_or_page}]` — the
  page's own Following list. Only followees that are still shown, the same gate
  a member's list applies to each kind.
  """
  def organization_followees(%Organization{id: page_id}, limit \\ 100) do
    page_id
    |> organization_followee_entries_query(limit)
    |> Enum.map(fn {follow, followee} -> {follow.id, followee} end)
  end

  @doc """
  The page's visible local follows with their edge, as
  `[{%Follow{}, member_or_page}]`. The management UI needs the edge's mute flag;
  callers that only render accounts should keep using
  `organization_followees/2`.
  """
  def organization_followee_entries(%Organization{id: page_id}, limit),
    do: organization_followee_entries_query(page_id, limit)

  def organization_followee_entries(%Organization{id: page_id}),
    do: organization_followee_entries_query(page_id, 100)

  defp organization_followee_entries_query(page_id, limit) do
    Repo.all(
      from(f in Follow,
        left_join: u in assoc(f, :followee),
        left_join: o in Organization,
        on: o.id == f.followee_organization_id,
        where: f.follower_organization_id == ^page_id,
        where: visible_member(u) or visible_page(o),
        order_by: [desc: f.inserted_at, desc: f.id],
        limit: ^limit,
        select: {f, u, o}
      )
    )
    |> Enum.map(fn {follow, user, organization} -> {follow, user || organization} end)
  end

  @doc "How many things `page` follows."
  def organization_followee_count(%Organization{id: page_id}) do
    Repo.aggregate(
      from(f in Follow,
        left_join: u in assoc(f, :followee),
        left_join: o in Organization,
        on: o.id == f.followee_organization_id,
        where: f.follower_organization_id == ^page_id,
        where: visible_member(u) or visible_page(o)
      ),
      :count
    )
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
    # Idempotent: a double-click / double-DELETE (the edge already gone) or a
    # tampered non-UUID `follow_id` is a no-op, not a crash. The lookup stays
    # scoped to `follower_id`, so a caller can still only drop their own edge.
    with uuid when not is_nil(uuid) <- Vutuv.UUIDv7.cast_or_nil(follow_id),
         %Follow{} = follow <- Repo.get_by(Follow, id: uuid, follower_id: follower_id) do
      deleted = Repo.delete!(follow)
      # The followee loses a follower and the pair may stop being mutual, so both
      # profiles recompute their counts live.
      broadcast_social_graph_changed([follower_id, follow.followee_id])
      deleted
    else
      _ -> :ok
    end
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
    |> Follow.mute_changeset(%{muted: not follow.muted})
    |> Repo.update!()
  end

  @doc "Sets the mute flag on a member's existing local follow."
  def set_follow_mute(%User{id: follower_id}, followee, muted?) when is_boolean(muted?) do
    {column, followee_id} = followee_column(followee)

    set_follow_mute(
      %{column => followee_id, follower_id: follower_id},
      muted?
    )
  end

  @doc "Sets the mute flag on an organization's existing local follow."
  def set_follow_mute_as_organization(%Organization{id: page_id}, followee, muted?)
      when is_boolean(muted?) do
    {column, followee_id} = followee_column(followee)

    set_follow_mute(
      %{column => followee_id, follower_organization_id: page_id},
      muted?
    )
  end

  @doc "Sets mute on one of a page's own local follow edges, scoped by edge id."
  def set_follow_edge_mute_as_organization(
        %Organization{id: page_id},
        follow_id,
        muted?
      )
      when is_boolean(muted?) do
    with id when not is_nil(id) <- UUIDv7.cast_or_nil(follow_id),
         %Follow{} = follow <-
           Repo.get_by(Follow, id: id, follower_organization_id: page_id) do
      follow |> Follow.mute_changeset(%{muted: muted?}) |> Repo.update()
    else
      _missing_or_invalid -> {:error, :not_following}
    end
  end

  defp set_follow_mute(filters, muted?) do
    case Repo.get_by(Follow, filters) do
      %Follow{} = follow -> follow |> Follow.mute_changeset(%{muted: muted?}) |> Repo.update()
      nil -> {:error, :not_following}
    end
  end

  # The public pages only count/show follows from activated accounts (nil
  # covers legacy rows that predate the flag) that moderation has not hidden,
  # matching Follow.latest/2. The gate sits on the counted person only — the
  # other end is the page owner, who may be a frozen member viewing their own
  # lists through the moderation bypass.

  def follower_count(user), do: Repo.one(follower_count_query(user.id)).total

  def followee_count(user), do: Repo.one(followee_count_query(user.id)).total

  @doc """
  The three profile-header counts — followers, followees, connections — in one
  round trip as `%{followers:, followees:, connections:}`: a union of the same
  three count queries the singles run, so the gates cannot drift. The profile
  renders all three on every mount (and social-graph refresh), and each single
  count walks every follow row of the member with a users join, so paying the
  scan once instead of three times is what this exists for.
  """
  def social_counts(%User{id: user_id}) do
    counts =
      follower_count_query(user_id)
      |> union_all(^followee_count_query(user_id))
      |> union_all(^connection_count_query(user_id))
      |> Repo.all()
      |> Map.new(fn %{kind: kind, total: total} -> {kind, total} end)

    %{
      followers: Map.get(counts, "followers", 0),
      followees: Map.get(counts, "followees", 0),
      connections: Map.get(counts, "connections", 0)
    }
  end

  @doc """
  The three tagged count queries behind `social_counts/1`, for a caller that
  folds them into a wider union instead of running them alone — the profile
  mounts fold them into their single per-mount counts query. Each arm selects
  `%{kind:, total:}` with kinds `"followers"` / `"followees"` / `"connections"`.
  """
  def profile_count_queries(user_id) do
    [
      follower_count_query(user_id),
      followee_count_query(user_id),
      connection_count_query(user_id)
    ]
  end

  # The tagged single-count queries behind both the single accessors and
  # `social_counts/1`'s union (a union's arms must share one select shape, so
  # the singles carry the tag too and read `.total` off the one row).
  # Followers are members **and** pages (issue #1336). A page that follows you
  # is shown and counted: hiding it would make the number lie, and would let a
  # page know something about you that you cannot see. Hence LEFT joins and one
  # gate per kind — the inner join this used to be dropped a page silently.
  defp follower_count_query(user_id) do
    from(c in Follow,
      left_join: u in assoc(c, :follower),
      left_join: o in Organization,
      on: o.id == c.follower_organization_id,
      where: c.followee_id == ^user_id,
      where: visible_member(u) or visible_page(o),
      select: %{kind: type(^"followers", :string), total: count(c.id)}
    )
  end

  # Following counts **both kinds** (issue #1336): a followed page is something
  # the member follows, so leaving it out made the profile header disagree with
  # what they had done. Hence two LEFT joins and one gate per kind rather than
  # the inner join this used to be — an organization follow has `followee_id IS
  # NULL` and an inner join to `users` drops it silently.
  #
  # The list underneath splits the two into their own sections, so its pager
  # counts members alone (`followee_member_count_query/1`). This one is the
  # figure a person reads.
  defp followee_count_query(user_id) do
    from(c in Follow,
      left_join: u in assoc(c, :followee),
      left_join: o in Organization,
      on: o.id == c.followee_organization_id,
      where: c.follower_id == ^user_id,
      where: visible_member(u) or visible_page(o),
      select: %{kind: type(^"followees", :string), total: count(c.id)}
    )
  end

  defp follower_member_count_query(user_id) do
    from(c in Follow,
      join: u in assoc(c, :follower),
      where: account_confirmed_row(u) and not account_hidden_row(u),
      where: c.followee_id == ^user_id,
      select: %{kind: type(^"followers", :string), total: count(c.id)}
    )
  end

  defp followee_member_count_query(user_id) do
    from(c in Follow,
      join: u in assoc(c, :followee),
      where: account_confirmed_row(u) and not account_hidden_row(u),
      where: c.follower_id == ^user_id,
      select: %{kind: type(^"followees", :string), total: count(c.id)}
    )
  end

  @doc """
  Whether `user` follows at least one other account — the same activated,
  non-hidden population `followee_count/1` counts, but as a cheap `EXISTS`.

  Drives where a member's "home" is (`VutuvWeb.Home`): the newsfeed only has
  something to show once you follow someone, so until then (most visibly right
  after sign-up) home is the member's own profile instead of an empty feed.

  **A followed page counts** (issue #1336). The member arm reaches the followee
  through an inner join to `users`, so an organization follow — `followee_id IS
  NULL` — was invisible to it, and somebody who followed three company pages was
  told they follow nobody and sent to their own profile while their feed was
  filling up with those pages' posts. The two arms are separate `EXISTS` queries
  rather than one union because `or` short-circuits: the ordinary case (a member
  who follows members) costs exactly what it cost before.
  """
  def follows_anyone?(%User{id: id}), do: follows_anyone?(id)

  def follows_anyone?(user_id) do
    Repo.exists?(followed_member_query(user_id)) or
      Repo.exists?(followed_page_query(user_id))
  end

  defp followed_member_query(user_id) do
    from(c in Follow,
      join: u in assoc(c, :followee),
      where: account_confirmed_row(u) and not account_hidden_row(u),
      where: c.follower_id == ^user_id
    )
  end

  # A page the member follows that is still shown. `status` is the page's own
  # gate, the organization twin of the confirmed/not-hidden pair above: a
  # follower of a frozen page should not be sent to a feed it cannot fill.
  defp followed_page_query(user_id) do
    from(c in Follow,
      join: o in Organization,
      on: o.id == c.followee_organization_id,
      where: c.follower_id == ^user_id,
      where: visible_page(o)
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
        # Members only on both sides. Pages are their own section on each page
        # (`follower_organizations/1`, `followed_organizations/1`), so neither
        # pager may count them; the profile-header figures do.
        :followers ->
          {Repo.one(follower_member_count_query(user.id)).total, :inbound_follows, :follower}

        :followees ->
          {Repo.one(followee_member_count_query(user.id)).total, :outbound_follows, :followee}
      end

    query = Follow.latest(100, person) |> Pages.paginate(params, total)
    user = Repo.preload(user, [{assoc, {query, [person]}}])

    %{
      user: user,
      users: user |> Map.fetch!(assoc) |> Enum.map(&Map.fetch!(&1, person)),
      total: total
    }
  end

  @doc """
  The pages `user` follows, newest follow first, as `[{follow_id, organization}]`
  — the "Organizations" section of their Following page (issue #1336).

  Its own function rather than another arm of `follows_page/3` because a page is
  not a row in `card_list`: it has a logo and neither work history nor tags, and
  the two kinds read better as two sections than as one interleaved list. Only
  **active** pages, matching the count and `follows_anyone?/1` — a follower of a
  frozen page is not shown a link that turns them away.

  The follow id rides along so the section can offer `DELETE /follows/:id`,
  which already handles an organization follow: its broadcast drops the nil
  followee. Without it the only way to unfollow a page was to find it again.

  Capped at `limit` (100, the same ceiling `Follow.latest/2` applies to the
  member list) — the count beside the section is the honest total.
  """
  def followed_organizations(%User{id: user_id}, limit \\ 100) do
    Repo.all(
      from(c in Follow,
        join: o in Organization,
        on: o.id == c.followee_organization_id,
        where: c.follower_id == ^user_id,
        where: visible_page(o),
        order_by: [desc: c.inserted_at, desc: c.id],
        limit: ^limit,
        select: {c.id, o}
      )
    )
  end

  @doc """
  The pages that follow `user`, newest first, as `[{follow_id, organization}]` —
  the "Organizations" section of their Followers page (issue #1336), the mirror
  of `followed_organizations/1`.

  No unfollow control here: this follow belongs to the page, not to the member
  being followed. A member who does not want it has blocking, which is a
  different question and not yet answered for pages.
  """
  def follower_organizations(%User{id: user_id}, limit \\ 100) do
    Repo.all(
      from(c in Follow,
        join: o in Organization,
        on: o.id == c.follower_organization_id,
        where: c.followee_id == ^user_id,
        where: visible_page(o),
        order_by: [desc: c.inserted_at, desc: c.id],
        limit: ^limit,
        select: {c.id, o}
      )
    )
  end

  @doc "How many shown pages follow `user`."
  def follower_organization_count(%User{id: user_id}) do
    Repo.aggregate(
      from(c in Follow,
        join: o in Organization,
        on: o.id == c.follower_organization_id,
        where: c.followee_id == ^user_id,
        where: visible_page(o)
      ),
      :count
    )
  end

  @doc "How many active pages `user` follows — the Organizations section's count."
  def followed_organization_count(%User{id: user_id}) do
    Repo.aggregate(
      from(c in Follow,
        join: o in Organization,
        on: o.id == c.followee_organization_id,
        where: c.follower_id == ^user_id,
        where: visible_page(o)
      ),
      :count
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
  Both directional follow edges between two members in one round trip, as
  `%{outbound:, inbound:}` — `outbound` the `a → b` edge and `inbound` the
  `b → a` edge, each `%{id:, muted?:}` or `nil`. The profile header resolves
  its whole relationship pill (follow id, mute state, follows-you, vernetzt)
  from exactly these two edges, so it reads them together instead of running
  `follow_edge/2` twice per mount.
  """
  def follow_edges_between(a_id, b_id) do
    edges =
      from(c in Follow,
        where:
          (c.follower_id == ^a_id and c.followee_id == ^b_id) or
            (c.follower_id == ^b_id and c.followee_id == ^a_id),
        select: {c.follower_id, %{id: c.id, muted?: c.muted}}
      )
      |> Repo.all()
      |> Map.new()

    %{outbound: Map.get(edges, a_id), inbound: Map.get(edges, b_id)}
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

  Served from the `Vutuv.Social.PopularUsers` snapshot (refreshed every few
  minutes) when available, so the hot paths never pay for the ranking scan;
  a cache miss falls back to the direct query.
  """
  def most_followed_users(limit) do
    case PopularUsers.top(limit) do
      {:ok, users} -> users
      :miss -> compute_most_followed(limit)
    end
  end

  @doc """
  The newest followers of `user_id` that they do not follow back, newest
  first - the /notifications rail's "Follow back" suggestions. Blocks (either
  direction) are filtered out belt-and-braces: a block severs the follow
  edges, so such a row should not exist in the first place.
  """
  def followers_to_follow_back(user_id, limit) do
    blocked = blocked_user_ids(user_id)

    from(f in Follow,
      as: :follow,
      join: u in User,
      on: u.id == f.follower_id,
      where: f.followee_id == ^user_id,
      where:
        not exists(
          from(b in Follow,
            where:
              b.follower_id == ^user_id and
                b.followee_id == parent_as(:follow).follower_id
          )
        ),
      order_by: [desc: f.inserted_at, desc: f.id],
      limit: ^(limit + 20),
      select: struct(u, ^User.listing_fields())
    )
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(blocked, &1.id))
    |> Enum.take(limit)
  end

  @doc """
  The uncached ranking behind `most_followed_users/1` — one GROUP BY over
  `follows`. Called by `Vutuv.Social.PopularUsers` on its refresh timer and
  as the direct fallback while no snapshot exists; don't call it from
  request paths.
  """
  def compute_most_followed(limit) do
    # Count each followee's *visible* followers, so the ranking matches the
    # follower_count/1 shown on each profile and can't be inflated by
    # mass-registering never-activated follower accounts.
    #
    # That promise is why this counts pages too (issue #1336): the profile
    # figure started counting them in v7.249.0, so an inner join to `users`
    # here would have quietly ranked by a different number than the one beside
    # each name. Same two LEFT joins and same gate per kind as
    # `follower_count_query/1`.
    follower_counts =
      from(fl in Follow,
        left_join: fr in User,
        on: fr.id == fl.follower_id,
        left_join: fo in Organization,
        on: fo.id == fl.follower_organization_id,
        where: visible_member(fr) or visible_page(fo),
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

    if match?({:ok, _}, result) do
      # In the blocker's own activity log (issue #1087), so "why can this person
      # not write to me any more" has a date. Recorded at the context chokepoint
      # rather than at the three call sites (the /blocks form, the profile
      # LiveView's menu, the block-and-report flow), which is why it carries no
      # request IP: two of the three have a socket, not a conn. The handle is
      # public identity, so it goes in whole.
      AccountEvents.record(blocker, "member_blocked", details: %{handle: blocked.username})

      broadcast_presence_blocks([blocker.id, blocked.id])
      # A block severs both follow edges (sever_between/2 is quiet by design), so
      # both members' open profiles must recompute their follower / following /
      # connection counts and the viewer's pill just like do_follow/unfollow! do.
      broadcast_social_graph_changed([blocker.id, blocked.id])
    end

    result
  end

  # Tell both members' open shells to refresh their online-dot block filter, so
  # a block/unblock hides (or restores) the pair's dots without a page reload.
  defp broadcast_presence_blocks(user_ids),
    do: Enum.each(user_ids, &Vutuv.Activity.broadcast(&1, :presence_blocks_changed))

  # Tell both members' open profiles to recompute their follower / following /
  # connection counts and the viewer's follow-state pill, so a follow/unfollow
  # shows live — even when it was made on another page or by the other member.
  # `VutuvWeb.UserProfileLive` listens for `:social_graph_changed`; every other
  # subscriber of the user topic ignores it (catch-all handle_info).
  defp broadcast_social_graph_changed(user_ids) do
    user_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(&Vutuv.Activity.broadcast(&1, {:social_graph_changed, %{}}))
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

        AccountEvents.record(blocker, "member_unblocked", details: %{handle: blocked.username})

        broadcast_presence_blocks([blocker.id, blocked.id])
        # Lifting the block changes the follow-state pill (the pair can interact
        # again), so refresh both open profiles the same way a block does.
        broadcast_social_graph_changed([blocker.id, blocked.id])
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
      case Vutuv.Engagement.insert_if_new(
             schema,
             %{user_id: user.id, target_user_id: target.id},
             [:user_id, :target_user_id]
           ) do
        :exists -> :ok
        {:inserted, _} -> broadcast_user_engagement(kind, user.id, target.id, true)
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
        # The saved-people row renders only name parts, @handle, headline and the
        # avatar, so select just those columns (listing_fields/0 + headline)
        # instead of every wide user column.
        select: struct(t, ^[:headline | User.listing_fields()])
      )
      |> filter_saved_search(search)
      |> order_saved(sort)
      |> limit(^(limit + 1))
      |> offset(^offset)
      |> Repo.all()

    Pages.offset_page(rows, limit, offset)
  end

  defp filter_saved_search(query, nil), do: query

  defp filter_saved_search(query, term) do
    pattern = contains(term)

    from([target: t] in query,
      where:
        name_ilike(t.first_name, t.last_name, ^pattern) or
          ilike(t.username, ^pattern) or ilike(t.headline, ^pattern)
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
    user_id
    |> ordered_connections_query()
    |> Repo.all()
  end

  @doc """
  One page of `user`'s vernetzt list for the public `/:slug/connections` page,
  bounding the query on a crawlable URL the way `follows_page/3` bounds the
  follower/following lists. Returns `%{user:, connections:, total:}`.
  """
  def connections_page(%User{id: user_id} = user, params) do
    total = connection_count(user)

    connections =
      user_id
      |> ordered_connections_query()
      |> Pages.paginate(params, total)
      |> Repo.all()

    %{user: user, connections: connections, total: total}
  end

  @doc """
  How many people `user` is vernetzt with (mutual follows) — same visibility
  rule as `list_connections/1`, so the profile count never disagrees with the
  list.
  """
  def connection_count(%User{id: user_id}) do
    Repo.one(connection_count_query(user_id)).total
  end

  defp connection_count_query(user_id) do
    mutual_follows_query(user_id)
    |> select([out], %{kind: type(^"connections", :string), total: count(out.id)})
  end

  # The mutual-follow set ordered newest-pair-first and shaped into the
  # `%{user:, follow_id:, muted?:}` rows both the full list and the paginated
  # connections page render.
  defp ordered_connections_query(user_id) do
    mutual_follows_query(user_id)
    |> order_by([out, back], desc: fragment("GREATEST(?, ?)", out.id, back.id))
    |> select([out, _back, o], %{user: o, follow_id: out.id, muted?: out.muted})
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
end
