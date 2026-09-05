defmodule Vutuv.Mutes do
  @moduledoc """
  Whose posts a reader does not want to see, and how much of them.

  Muting used to live on the follow edge — `follows.muted` here,
  `fediverse_follows.muted` out there — which answers "I follow you but I do
  not want to read you today" and nothing else. The account a reader actually
  wants gone is usually one they never followed: a followed account boosts the
  same stranger every day, and there is no edge to carry the flag. So a mute is
  a row about an **account**, and `account_mutes` is where one lives when there
  is no follow to hang it on.

  Two scopes, because the two complaints are different. `:all` is "not this
  account, ever, whoever passes them on". `:reposts` is "your own posts yes,
  what you pass on no" — the one that names an account the reader follows and
  wants to keep.

  ## One question, one answer

  Two stores now hold a mute, so nothing outside this module reads or writes
  one of them alone. `scope_for/2` and `silenced?/4` answer from both; `mute/3`
  and `unmute/2` write both; and the older switches that still spell an unmute
  in terms of the follow flag (`Social.set_follow_mute/3`,
  `Social.toggle_follow_mute!/2`, `Fediverse.set_remote_follow_mute/3` and its
  toggle) call `forget_id/3` on their way past, so lifting a mute anywhere
  lifts all of it. A caller asking `follows.muted` on its own gets yesterday's
  answer for every account the reader never followed, which is the whole point
  of this table.

  The feed reads the sets as **queries** rather than through that function, so a
  page costs no extra round trip: `silenced_member_ids/2`,
  `silenced_organization_ids/2`, `silenced_remote_account_ids/2` and
  `silenced_remote_rows/1` are subqueries the sources fold into their own — and
  every one of them is the **union** of both stores, so a source cannot read
  half the answer by forgetting the other half. Each excludes NULLs at the
  source, because these lists feed `NOT IN` and `x NOT IN (…, NULL)` is never
  true. `silenced_ids/3` is the same as a plain list, for the boost source,
  whose whole shape is constant id lists.

  ## What a mute does not reach

  A conversation the reader opens themselves (a post's permalink page, a
  thread), their notifications, and the profile of the muted account all still
  show it. A mute is about what arrives unasked; going and looking is asking.
  """

  import Ecto.Query, warn: false

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Mutes.AccountMute
  alias Vutuv.Organizations.Organization
  alias Vutuv.Repo
  alias Vutuv.Social.Follow
  alias Vutuv.UUIDv7

  @doc """
  Silences `target` for `viewer` at `scope` (`:all` or `:reposts`).

  Idempotent, and a scope change is an update of the one row rather than a
  second one beside it. When the reader follows the target, the follow's own
  mute flag is set too for `:all` — it is the flag every existing surface
  reads (the account page, the following list, the feed band), and leaving the
  two disagreeing is how a member ends up muted in one place and loud in
  another.
  """
  def mute(%User{} = viewer, target, scope \\ :all) when scope in [:all, :reposts] do
    with {:ok, mute} <-
           %AccountMute{user_id: viewer.id}
           |> AccountMute.changeset(target, scope)
           |> Repo.insert(
             on_conflict: [set: [scope: scope, updated_at: NaiveDateTime.utc_now(:second)]],
             conflict_target: conflict_target(target)
           ) do
      # Unconditionally, both ways. Narrowing a whole-account mute to its
      # reposts has to take the follow's flag back down, or the account stays
      # silenced by the older store while this page says only its reposts are —
      # a mute the member cannot see and cannot lift.
      set_follow_mute(viewer, target, scope == :all)
      {:ok, mute}
    end
  end

  @doc """
  Lifts every mute `viewer` holds on `target`, in both stores.

  Both, always: a reader who muted an account before following it and used the
  follow's own switch afterwards has two rows saying the same thing, and
  "unmute" that leaves one of them is a button that does nothing.
  """
  def unmute(%User{} = viewer, target) do
    forget(viewer, target)
    set_follow_mute(viewer, target, false)
    :ok
  end

  @doc """
  Drops the row this table holds about `target`, and touches no follow.

  What the **older** switches call when they turn a follow's mute off — the
  profile's ⋯ menu, the following lists, the feed band. They knew only the
  flag, so without this a member who muted an account from a card and unmuted
  it on the profile lifted half of it: the flag went, the row stayed, and the
  posts stayed away with no switch left showing them why. Every "unmute" has to
  reach both stores, whichever surface it is spelled on.
  """
  def forget(%User{} = viewer, target), do: forget(viewer.id, target)

  def forget(viewer_id, target) when is_binary(viewer_id) do
    Repo.delete_all(from(m in AccountMute, where: ^target_match(viewer_id, target)))
    :ok
  end

  @doc """
  The same, for a switch that holds ids rather than records — a follow row's
  `followee_id` / `remote_account_id`, which is what the toggles have in hand.
  """
  def forget_id(viewer_id, kind, id) when is_binary(id) do
    column = column_for(kind)

    Repo.delete_all(
      from(m in AccountMute,
        where: m.user_id == ^viewer_id and field(m, ^column) == ^id
      )
    )

    :ok
  end

  def forget_id(_viewer_id, _kind, nil), do: :ok

  @doc """
  How far `viewer` has silenced `target`: `:all`, `:reposts`, or `nil`.

  The one place that reads both stores. A follow's own mute is `:all` — it has
  no scope of its own — and wins over a `:reposts` row, since the narrower
  answer would be a lie about what the reader will see.
  """
  def scope_for(%User{} = viewer, target) do
    if follow_muted?(viewer, target) do
      :all
    else
      Repo.one(from(m in AccountMute, where: ^target_match(viewer.id, target), select: m.scope))
    end
  end

  @doc """
  The members `viewer` has silenced at one of `scopes`, as a subquery of ids —
  **both** stores in one list.

  Every reader asks for the union, never for one half: the half a caller
  forgets is silent, and a mute that holds in one source and not the next is
  the bug this module exists to prevent. `not is_nil` is not decoration either
  — the same list is negated by its callers, and one NULL in it makes `NOT IN`
  false for every row.
  """
  def silenced_member_ids(viewer_id, scopes) do
    mutes = muted_ids(viewer_id, :muted_user_id, scopes)

    if :all in scopes do
      union_all(
        mutes,
        ^from(f in Follow,
          where: f.follower_id == ^viewer_id and f.muted,
          where: not is_nil(f.followee_id),
          select: f.followee_id
        )
      )
    else
      mutes
    end
  end

  @doc "The pages `viewer` has silenced at one of `scopes`, both stores."
  def silenced_organization_ids(viewer_id, scopes) do
    mutes = muted_ids(viewer_id, :muted_organization_id, scopes)

    if :all in scopes do
      union_all(
        mutes,
        ^from(f in Follow,
          where: f.follower_id == ^viewer_id and f.muted,
          where: not is_nil(f.followee_organization_id),
          select: f.followee_organization_id
        )
      )
    else
      mutes
    end
  end

  @doc "The accounts out there `viewer` has silenced at one of `scopes`, both stores."
  def silenced_remote_account_ids(viewer_id, scopes) do
    mutes = muted_ids(viewer_id, :muted_remote_account_id, scopes)

    if :all in scopes do
      union_all(
        mutes,
        ^from(f in Vutuv.Fediverse.Follow,
          where: f.user_id == ^viewer_id and f.muted,
          select: f.remote_account_id
        )
      )
    else
      mutes
    end
  end

  # The one shape all three share: which column carries the target, and which
  # scopes count. Written once with `field/2` rather than three times with a
  # column name, because the NULL guard has to be right in all of them.
  defp muted_ids(viewer_id, column, scopes) do
    from(m in AccountMute,
      where: m.user_id == ^viewer_id and m.scope in ^scopes,
      where: not is_nil(field(m, ^column)),
      select: field(m, ^column)
    )
  end

  @doc """
  The whole-account mutes of remote accounts, shaped like `Vutuv.Fediverse`'s
  follow rows, so that source can union them into the one lookup it already
  makes rather than paying a second round trip per feed page.

  They arrive marked `muted: true` — which is what they are — so nothing on the
  other side needs an arm for them. A `:reposts` mute is deliberately absent:
  it leaves the account itself heard, so it is not this question.
  """
  def silenced_remote_rows(viewer_id) do
    from(m in AccountMute,
      where: m.user_id == ^viewer_id and m.scope == :all,
      where: not is_nil(m.muted_remote_account_id),
      select: %{
        account_id: m.muted_remote_account_id,
        state: type(^"", :string),
        muted: type(^true, :boolean)
      }
    )
  end

  @doc """
  Whether `viewer_id` has silenced this one member, page or account at one of
  `scopes` — both stores, one round trip.

  For a caller holding ids rather than records and asking about a single post:
  the feed's in-memory arrival check, which has to answer exactly what the
  query answers or the "new posts" pill counts what the next load throws away.
  """
  def silenced?(viewer_id, kind, id, scopes \\ [:all])

  def silenced?(viewer_id, kind, id, scopes) when is_binary(id) do
    # Two small indexed lookups rather than one union: a subquery may not select
    # a constant in Ecto, and the second only runs when the first found nothing.
    row_silences?(viewer_id, kind, id, scopes) or follow_silences?(viewer_id, kind, id, scopes)
  end

  def silenced?(_viewer_id, _kind, _id, _scopes), do: false

  defp row_silences?(viewer_id, kind, id, scopes) do
    column = column_for(kind)

    Repo.exists?(
      from(m in AccountMute,
        where: m.user_id == ^viewer_id and m.scope in ^scopes,
        where: field(m, ^column) == ^id
      )
    )
  end

  # The follow's own flag is the whole account, so it answers only when the
  # caller is asking about the whole account.
  defp follow_silences?(viewer_id, kind, id, scopes),
    do: :all in scopes and Repo.exists?(follow_mutes(viewer_id, kind, id))

  defp follow_mutes(viewer_id, :member, id) do
    from(f in Follow, where: f.follower_id == ^viewer_id and f.followee_id == ^id and f.muted)
  end

  defp follow_mutes(viewer_id, :organization, id) do
    from(f in Follow,
      where: f.follower_id == ^viewer_id and f.followee_organization_id == ^id and f.muted
    )
  end

  defp follow_mutes(viewer_id, :remote_account, id) do
    from(f in Vutuv.Fediverse.Follow,
      where: f.user_id == ^viewer_id and f.remote_account_id == ^id and f.muted
    )
  end

  @doc """
  The ids `viewer` has silenced at `scopes`, read once as a plain list — for a
  caller that wants a **constant** in its query rather than a subquery.

  The boost source is that caller: its whole shape is constant id lists, which
  is what keeps it on its recency index.
  """
  def silenced_ids(viewer_id, kind, scopes) do
    viewer_id |> muted_ids(column_for(kind), scopes) |> Repo.all()
  end

  defp column_for(:member), do: :muted_user_id
  defp column_for(:organization), do: :muted_organization_id
  defp column_for(:remote_account), do: :muted_remote_account_id

  @doc """
  Everything `viewer` has silenced, newest first — what `/settings/mutes`
  lists.

  Both stores, in one list: a follow mute placed from an account page and a
  row placed from a card are the same thing to the member who wants to know
  why an account is quiet, and a page that showed only one of them would send
  them looking for a switch that is not there. Each entry carries its target
  (a member, a page, or a remote account), its scope, and where it is stored,
  which is what `unmute/2` needs to take it back.
  """
  def list_for_user(%User{} = viewer) do
    rows = account_mute_entries(viewer)

    (rows ++ follow_mute_entries(viewer, rows))
    |> Enum.sort_by(& &1.at, {:desc, NaiveDateTime})
  end

  defp account_mute_entries(%User{id: viewer_id}) do
    from(m in AccountMute,
      where: m.user_id == ^viewer_id,
      preload: [:muted_user, :muted_organization, :muted_remote_account],
      order_by: [desc: m.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(fn mute ->
      %{
        target: mute.muted_user || mute.muted_organization || mute.muted_remote_account,
        scope: mute.scope,
        source: :mute,
        at: mute.inserted_at
      }
    end)
  end

  # The follow flags, as the same entry shape. A muted follow is always `:all`:
  # it has no scope of its own, and the account it names is one the reader
  # follows, so leaving it out would hide the mutes members placed before this
  # table existed.
  defp follow_mute_entries(%User{id: viewer_id}, account_entries) do
    local =
      from(f in Follow,
        where: f.follower_id == ^viewer_id and f.muted,
        preload: [:followee, :followee_organization]
      )
      |> Repo.all()
      |> Enum.map(&%{target: &1.followee || &1.followee_organization, at: &1.updated_at})

    remote =
      from(f in Vutuv.Fediverse.Follow,
        where: f.user_id == ^viewer_id and f.muted,
        preload: [:remote_account]
      )
      |> Repo.all()
      |> Enum.map(&%{target: &1.remote_account, at: &1.updated_at})

    muted_twice = MapSet.new(account_entries, & &1.target.id)

    (local ++ remote)
    |> Enum.reject(&(&1.target == nil or MapSet.member?(muted_twice, &1.target.id)))
    |> Enum.map(&Map.merge(&1, %{scope: :all, source: :follow}))
  end

  @doc """
  What a silenced account is called, where its page is, and how its address is
  written — for the surfaces that list mutes.

  Three thin functions rather than each surface matching on the struct again:
  a member and a page are `Vutuv.Identity`'s question (which is also what knows
  that a page's path is `Organizations.canonical_path/1`, not `/<slug>`), and an
  account on another network is not an identity here, so this is where the
  third arm lives.
  """
  def display_name(%RemoteAccount{} = account), do: RemoteAccount.label(account)
  def display_name(identity), do: Vutuv.Identity.display_name(identity)

  @doc "The address under the name: `@handle` here, `@user@host` out there."
  def handle(%RemoteAccount{} = account), do: RemoteAccount.display_handle(account)

  def handle(identity) do
    case Vutuv.Identity.handle(identity) do
      nil -> nil
      handle -> "@" <> handle
    end
  end

  @doc "Where the silenced account's own page is."
  def path(%RemoteAccount{id: id}), do: "/system/fediverse/account/#{id}"
  def path(identity), do: Vutuv.Identity.path(identity)

  @doc """
  Resolves the `kind`/`id` pair a card's menu sends into the record to mute.

  The card names a kind rather than handing over a struct, and this is where
  that string becomes one — `nil` for anything that does not resolve, so an
  invented id is a no-op rather than a crash.
  """
  def target(kind, id)

  def target("member", id), do: UUIDv7.with_cast(id, &Repo.get(User, &1))
  def target("organization", id), do: UUIDv7.with_cast(id, &Repo.get(Organization, &1))
  def target("remote_account", id), do: UUIDv7.with_cast(id, &Repo.get(RemoteAccount, &1))
  def target(_kind, _id), do: nil

  @doc "The kind string for a target, the inverse of `target/2`."
  def kind(%User{}), do: "member"
  def kind(%Organization{}), do: "organization"
  def kind(%RemoteAccount{}), do: "remote_account"

  # The unique indexes behind these are **partial** (two of the three target
  # columns are NULL on every row), and Postgres only matches an ON CONFLICT to
  # a partial index when the predicate comes with it — a bare column list is
  # answered with 42P10.
  defp conflict_target(%User{}), do: target_fragment("muted_user_id")
  defp conflict_target(%Organization{}), do: target_fragment("muted_organization_id")
  defp conflict_target(%RemoteAccount{}), do: target_fragment("muted_remote_account_id")

  defp target_fragment(column),
    do: {:unsafe_fragment, "(user_id, #{column}) WHERE #{column} IS NOT NULL"}

  defp target_match(viewer_id, %User{id: id}),
    do: dynamic([m], m.user_id == ^viewer_id and m.muted_user_id == ^id)

  defp target_match(viewer_id, %Organization{id: id}),
    do: dynamic([m], m.user_id == ^viewer_id and m.muted_organization_id == ^id)

  defp target_match(viewer_id, %RemoteAccount{id: id}),
    do: dynamic([m], m.user_id == ^viewer_id and m.muted_remote_account_id == ^id)

  # The follow's own flag, where there is a follow — written here rather than
  # through `Social`/`Fediverse`, and deliberately: those two call **back** into
  # this module to clear a row when their own switches unmute, so routing this
  # write through them would have `mute(_, _, :reposts)` delete the row it had
  # just written. One `update_all`, no round trip wasted on an account the
  # reader does not follow, which is the case this table exists for.
  defp set_follow_mute(%User{id: viewer_id}, %RemoteAccount{id: id}, muted?) do
    from(f in Vutuv.Fediverse.Follow,
      where: f.user_id == ^viewer_id and f.remote_account_id == ^id
    )
    |> flip_mute(muted?)
  end

  defp set_follow_mute(%User{id: viewer_id}, %User{id: id}, muted?) do
    from(f in Follow, where: f.follower_id == ^viewer_id and f.followee_id == ^id)
    |> flip_mute(muted?)
  end

  defp set_follow_mute(%User{id: viewer_id}, %Organization{id: id}, muted?) do
    from(f in Follow,
      where: f.follower_id == ^viewer_id and f.followee_organization_id == ^id
    )
    |> flip_mute(muted?)
  end

  defp flip_mute(query, muted?) do
    Repo.update_all(query,
      set: [muted: muted?, updated_at: NaiveDateTime.utc_now(:second)]
    )

    :ok
  end

  defp follow_muted?(%User{id: viewer_id}, %RemoteAccount{id: id}) do
    Repo.exists?(
      from(f in Vutuv.Fediverse.Follow,
        where: f.user_id == ^viewer_id and f.remote_account_id == ^id and f.muted
      )
    )
  end

  defp follow_muted?(%User{id: viewer_id}, %User{id: id}) do
    Repo.exists?(
      from(f in Follow, where: f.follower_id == ^viewer_id and f.followee_id == ^id and f.muted)
    )
  end

  defp follow_muted?(%User{id: viewer_id}, %Organization{id: id}) do
    Repo.exists?(
      from(f in Follow,
        where: f.follower_id == ^viewer_id and f.followee_organization_id == ^id and f.muted
      )
    )
  end
end
