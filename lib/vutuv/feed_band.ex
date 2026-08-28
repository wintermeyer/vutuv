defmodule Vutuv.FeedBand do
  @moduledoc """
  What the feed's filter band lists, and what the numbers beside each row mean.

  The band replaces the old All / vutuv / Fediverse tabs: instead of three
  places to stand in, the reader keeps one timeline and switches individual
  accounts, whole fediverse servers, words and tags off. This module answers the
  *reading* half — who is in the list, in which order, with how much traffic —
  while the switches themselves stay where they already live: `follows.muted`
  and `fediverse_follows.muted` per account, `users.feed_muted_hosts` per
  server (`Vutuv.Fediverse.set_host_mute/3`), `Vutuv.ContentFilters` per word
  and tag. Nothing here writes.

  **The number beside a row is posts in the last seven days**, not the number of
  accounts followed and not an all-time total: the question the reader is asking
  when they open the band is "who is filling my feed", and that is a rate, not a
  stock. It also means the list can be ordered by it, which is the order that
  answers the question without being asked.

  A member follows a handful of fediverse accounts and can follow thousands of
  members here, so the two halves are read differently: the remote follows come
  back whole and are grouped by host in memory, while the local ones are sorted
  and cut down to `top` in SQL — plus, always, whatever the member has switched
  off, because a list that hides what you muted gives you no way to unmute it.

  **One search covers both halves.** `accounts/2` and `servers/2` take the same
  `query`, because the reader's question is "where is that account" and they
  routinely do not know which half it lives on — a person here today may be an
  account out there tomorrow. Two search boxes would make them guess, and a
  wrong guess answers "nothing found".
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Identity
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.Social.Follow

  # How far back the traffic figures look. Seven days smooths a weekend out and
  # is short enough that "who is loud right now" still shows.
  @window_days 7
  # How many rows a branch shows before the reader has to search or say "more".
  @top 6

  @doc "The window the counts are taken over, in days."
  def window_days, do: @window_days

  @doc """
  The accounts this member follows here, as band rows.

  `sort` is `:active` (posts in the window, the default), `:recent` (whoever
  posted last) or `:name`. `query` narrows by name or handle — which is what
  makes the branch usable at four digits of follows. `limit` caps the list;
  muted accounts are added on top of the cap rather than counted against it.
  """
  def accounts(%User{} = viewer, opts \\ []) do
    sort = Keyword.get(opts, :sort, :active)
    limit = Keyword.get(opts, :limit, @top)
    query = opts |> Keyword.get(:query) |> normalize_query()

    rows =
      [members_query(viewer, query, sort, limit), pages_query(viewer, query, sort, limit)]
      |> Enum.flat_map(&Repo.all/1)
      |> Enum.map(&row/1)

    muted = if query, do: [], else: muted_accounts(viewer, limit)

    (rows ++ muted)
    |> Enum.uniq_by(& &1.key)
    |> order(sort)
    |> Enum.take(limit + length(muted))
  end

  @doc """
  How many accounts this member follows here — the figure under the search
  field, and the reason the branch is a search rather than a list.
  """
  def account_count(%User{id: viewer_id}) do
    Repo.aggregate(from(f in Follow, where: f.follower_id == ^viewer_id), :count)
  end

  @doc """
  The fediverse servers this member's follows live on, newest traffic first,
  each with its accounts underneath.

  Remote follows are counted in dozens, so this reads them whole and groups in
  memory rather than asking the database twice. A server carries the sum of its
  accounts' posts, so the reader can decide at either level with the same
  number in front of them.
  """
  def servers(%User{} = viewer, opts \\ []) do
    muted_hosts = Fediverse.muted_hosts(viewer)
    query = opts |> Keyword.get(:query) |> normalize_query()

    from(f in Fediverse.Follow,
      join: a in RemoteAccount,
      on: a.id == f.remote_account_id,
      left_join: p in RemotePost,
      on: p.remote_account_id == a.id and p.published_at > ^utc_since(),
      where: f.user_id == ^viewer.id,
      group_by: [a.id, f.muted],
      select: %{account: a, muted: f.muted, posts: count(p.id), last_at: max(p.published_at)}
    )
    |> Repo.all()
    |> Enum.group_by(& &1.account.host)
    |> Enum.map(fn {host, rows} -> server(host, rows, muted_hosts) end)
    |> narrow_servers(query)
    |> Enum.sort_by(&{-&1.posts, &1.host})
  end

  @doc """
  Whether the member has any account switched off, local or remote.

  Two `exists?` probes rather than a list, because after an account's "only" the
  muted set is every follow they have and the only question the card asks of it
  is whether the way back should be offered at all.
  """
  def accounts_muted?(%User{} = viewer) do
    Repo.exists?(from(f in Follow, where: f.follower_id == ^viewer.id and f.muted)) or
      Repo.exists?(from(f in Fediverse.Follow, where: f.user_id == ^viewer.id and f.muted))
  end

  @doc """
  Every host this member follows somebody on, whatever the card is showing.

  `servers/2` narrows to the search box, which is right for a list and wrong for
  a bulk switch: "only this server" and "clear all" have to name the hosts they
  are switching off, and reading them off a narrowed list left the
  non-matching ones quietly on. So the write path asks here and the list path
  asks `servers/2`.
  """
  def hosts(%User{} = viewer) do
    Repo.all(
      from(f in Fediverse.Follow,
        join: a in RemoteAccount,
        on: a.id == f.remote_account_id,
        where: f.user_id == ^viewer.id,
        distinct: true,
        select: a.host
      )
    )
  end

  # Narrowed in memory, unlike the vutuv half: the remote follows are already
  # all here. A server survives if its own host matches — then it keeps every
  # account, since the reader asked for the server — or if any of its accounts
  # does, and then it keeps exactly those. Its count is left alone: it says what
  # that server sends, not how much of it a search happens to show.
  defp narrow_servers(servers, nil), do: servers

  defp narrow_servers(servers, text) do
    needle = String.downcase(text)

    servers
    |> Enum.map(fn server ->
      if contains?(server.host, needle),
        do: server,
        else: %{server | accounts: Enum.filter(server.accounts, &account_matches?(&1, needle))}
    end)
    |> Enum.reject(&(&1.accounts == []))
  end

  defp account_matches?(account, needle),
    do: contains?(account.name, needle) or contains?(account.handle, needle)

  defp contains?(nil, _needle), do: false
  defp contains?(text, needle), do: String.contains?(String.downcase(text), needle)

  @doc """
  The tag names on a page of cached remote posts.

  A `%RemotePost{}` carries no tag association of its own — the join table is
  written by the inbox and read by the tag pages — so the band asks for them in
  one go rather than per row. Without this the tag suggestions would be blind on
  exactly the feed that needs them most: a reader whose page is mostly fediverse
  posts would be offered no tags at all.
  """
  def remote_tags([]), do: []

  def remote_tags(remote_post_ids) do
    Repo.all(
      from(pt in Vutuv.Fediverse.RemotePostTag,
        join: t in Vutuv.Tags.Tag,
        on: t.id == pt.tag_id,
        where: pt.remote_post_id in ^remote_post_ids,
        select: t.name
      )
    )
  end

  @doc """
  The tags on the page in front of the reader, most frequent first.

  Two cards ask it: "Hide tags" offers them to mute, "Tags you follow" offers
  them to follow. One list, because the answer to "what am I reading about right
  now" cannot be two different things a card apart — and because a `%RemotePost{}`
  keeps its tags in a join table the entry does not carry, which is a detail
  neither card should have to remember.

  `except` drops what the reader has already decided about, so nothing is
  offered twice; matched case-insensitively, since a tag's casing is
  first-writer-wins and the two cards see it in whatever spelling it was minted.
  """
  def tags_on_page(entries, opts \\ []) do
    except = opts |> Keyword.get(:except, []) |> MapSet.new(&String.downcase/1)
    limit = Keyword.get(opts, :limit, 6)

    # Matched rather than asked: `remote_feed_entry?/1` is also true for a
    # reshared *reply*, and that entry carries a `note` instead of a
    # `remote_post` — asking the predicate and then reaching for the field
    # raises on exactly those rows.
    remote_ids = for %{remote_post: %{id: id}} <- entries, do: id

    (Enum.flat_map(entries, &entry_tags/1) ++ remote_tags(remote_ids))
    |> Enum.reject(&(is_nil(&1) or String.downcase(&1) in except))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {tag, count} -> {-count, tag} end)
    |> Enum.take(limit)
    |> Enum.map(&elem(&1, 0))
  end

  defp entry_tags(%{post: %{tags: tags}}) when is_list(tags), do: Enum.map(tags, & &1.name)
  defp entry_tags(_entry), do: []

  @doc "Total posts from the vutuv half in the window."
  def vutuv_total(%User{} = viewer) do
    since = since()

    member_posts =
      from(f in Follow,
        join: p in Post,
        on: p.user_id == f.followee_id,
        where: f.follower_id == ^viewer.id and f.muted == false and p.inserted_at > ^since
      )

    page_posts =
      from(f in Follow,
        join: p in Post,
        on: p.organization_id == f.followee_organization_id,
        where: f.follower_id == ^viewer.id and f.muted == false and p.inserted_at > ^since
      )

    Repo.aggregate(member_posts, :count) + Repo.aggregate(page_posts, :count)
  end

  # ── queries ──

  defp members_query(viewer, query, sort, limit) do
    from(f in Follow,
      join: u in User,
      on: u.id == f.followee_id,
      left_join: p in Post,
      on: p.user_id == u.id and p.inserted_at > ^since(),
      where: f.follower_id == ^viewer.id and not is_nil(f.followee_id),
      group_by: [u.id, f.muted],
      select: %{subject: u, muted: f.muted, posts: count(p.id), last_at: max(p.inserted_at)},
      limit: ^limit
    )
    |> narrow_members(query)
    |> order_query(sort, :username)
  end

  defp pages_query(viewer, query, sort, limit) do
    from(f in Follow,
      join: o in Organization,
      on: o.id == f.followee_organization_id,
      left_join: p in Post,
      on: p.organization_id == o.id and p.inserted_at > ^since(),
      where: f.follower_id == ^viewer.id and not is_nil(f.followee_organization_id),
      group_by: [o.id, f.muted],
      select: %{subject: o, muted: f.muted, posts: count(p.id), last_at: max(p.inserted_at)},
      limit: ^limit
    )
    |> narrow_pages(query)
    |> order_query(sort, :slug)
  end

  # What the member switched off, carried past the cap so a silent account is
  # not also an invisible one — the card is where it goes back on.
  #
  # Bounded, and the bound is what makes the card survive its own bulk switch.
  # "Only this account" mutes every other follow the member has, so an unbounded
  # tail rendered 2,678 rows into a rail card the width of a phone (measured on
  # the dev copy, 2026-08-28) and the list stopped being a list. Past the bound
  # the way back is not a row anyway: it is the search field, "Select all", or
  # the undo beside them, all of which sit above this list.
  defp muted_accounts(%User{} = viewer, limit) do
    members =
      from(f in Follow,
        join: u in User,
        on: u.id == f.followee_id,
        where: f.follower_id == ^viewer.id and f.muted == true,
        select: %{subject: u, muted: f.muted, posts: 0, last_at: nil},
        limit: ^limit
      )

    pages =
      from(f in Follow,
        join: o in Organization,
        on: o.id == f.followee_organization_id,
        where: f.follower_id == ^viewer.id and f.muted == true,
        select: %{subject: o, muted: f.muted, posts: 0, last_at: nil},
        limit: ^limit
      )

    muted = Repo.all(members) ++ Repo.all(pages)

    muted |> Enum.map(&row/1) |> Enum.take(limit)
  end

  defp narrow_members(query, nil), do: query

  defp narrow_members(query, text) do
    like = "%#{text}%"

    where(
      query,
      [f, u],
      ilike(u.username, ^like) or ilike(u.first_name, ^like) or ilike(u.last_name, ^like)
    )
  end

  defp narrow_pages(query, nil), do: query

  defp narrow_pages(query, text) do
    like = "%#{text}%"
    where(query, [f, o], ilike(o.name, ^like) or ilike(o.slug, ^like))
  end

  # The sort has to be expressible in SQL, because it decides which rows survive
  # the `limit` — sorting afterwards would take the top six of an arbitrary six.
  # The handle column differs per kind (a member has `username`, a page a
  # `slug`), so the caller names it; the tie-break only has to be stable.
  defp order_query(query, :name, field), do: order_by(query, [_f, s], asc: field(s, ^field))

  defp order_query(query, :recent, _field),
    do: order_by(query, [_f, _s, p], desc_nulls_last: max(p.inserted_at))

  defp order_query(query, _active, field),
    do: order_by(query, [_f, s, p], desc: count(p.id), asc: field(s, ^field))

  defp order(rows, :name), do: Enum.sort_by(rows, &String.downcase(&1.name))

  defp order(rows, :recent),
    do: Enum.sort_by(rows, &{&1.last_at && -DateTime.to_unix(to_utc(&1.last_at)), &1.name})

  defp order(rows, _active), do: Enum.sort_by(rows, &{-&1.posts, String.downcase(&1.name)})

  # ── shaping ──

  defp row(%{subject: %User{} = user} = agg) do
    %{
      key: "user:" <> user.id,
      kind: :user,
      id: user.id,
      name: Identity.display_name(user),
      handle: "@" <> user.username,
      path: Identity.path(user),
      posts: agg.posts,
      last_at: agg.last_at,
      muted?: agg.muted
    }
  end

  defp row(%{subject: %Organization{} = org} = agg) do
    %{
      key: "page:" <> org.id,
      kind: :page,
      id: org.id,
      name: Identity.display_name(org),
      handle: org.slug && "@" <> org.slug,
      path: Identity.path(org),
      posts: agg.posts,
      last_at: agg.last_at,
      muted?: agg.muted
    }
  end

  defp server(host, rows, muted_hosts) do
    accounts =
      rows
      |> Enum.map(fn agg ->
        %{
          key: "remote:" <> agg.account.id,
          kind: :remote,
          id: agg.account.id,
          host: agg.account.host,
          name: agg.account.name || agg.account.handle,
          handle: Fediverse.Handle.short(agg.account.handle),
          path: "/system/fediverse/account/" <> agg.account.id,
          posts: agg.posts,
          last_at: agg.last_at,
          muted?: agg.muted
        }
      end)
      |> Enum.sort_by(&{-&1.posts, &1.handle})

    %{
      host: host,
      posts: Enum.reduce(accounts, 0, &(&1.posts + &2)),
      accounts: accounts,
      muted?: host in muted_hosts
    }
  end

  defp normalize_query(nil), do: nil

  defp normalize_query(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp since, do: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -@window_days, :day)
  defp utc_since, do: DateTime.add(DateTime.utc_now(:second), -@window_days, :day)

  defp to_utc(%DateTime{} = at), do: at
  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
end
