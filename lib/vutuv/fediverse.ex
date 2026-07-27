defmodule Vutuv.Fediverse do
  @moduledoc """
  ActivityPub federation.

  People on Mastodon and other Fediverse servers can follow a member who
  opted in (`users.fediverse_followers?`, the Fediverse settings page) and
  receive their **public** posts; the response to those posts comes back
  (reactions, replies), and since issue #1160 a member can follow an account
  out there in return. The moving parts:

    * actors — the member's RSA keypair (`Vutuv.Fediverse.Actor`), created
      lazily on opt-in; `VutuvWeb.Fediverse.Docs` renders the documents.
    * followers — remote actors following a member
      (`Vutuv.Fediverse.Follower`), written by the inbox on Follow/Undo and
      kept in step with the remote's own Update/Delete; the ones who leave
      without saying so are found by the slow re-check
      (`Vutuv.Fediverse.FollowerPruner`).
    * follows — the same relationship read from the other end
      (`Vutuv.Fediverse.Follow` pointing at `Vutuv.Fediverse.RemoteAccount`):
      a member asks to follow an account elsewhere, we send a signed `Follow`,
      and the `Accept` that comes back seals it. Both collections are published
      count-only.
    * deliveries — a DB-backed outbound queue (`Vutuv.Fediverse.Delivery`)
      drained by `Vutuv.Fediverse.Deliverer` with signed POSTs
      (`Vutuv.Fediverse.HttpSignature`), mirroring the webhooks queue.
    * revocations — every takedown asks the other servers to drop their copy:
      `revoke_post/1` for a post (from the owner's own delete *and* the
      moderation freezer), `revoke_actor/1` for a permanently removed account,
      and a `Flag` to the origin when a reply from another network is reported.
      `Vutuv.Fediverse.PostDelivery` records where each copy went and under which
      id, so a `Delete` is addressed rather than broadcast; a takedown that never
      arrives lands in `Vutuv.Fediverse.DeliveryFailure`.

  Everything sits behind the global `:fediverse_enabled` switch
  (FEDIVERSE_ENABLED, for installations that must not call out — intranets)
  and behind the per-member opt-in: consent first, because deletion of
  federated copies on remote servers is not enforceable.
  """

  use Gettext, backend: VutuvWeb.Gettext

  import Ecto.Query
  import Vutuv.Moderation.Query, only: [account_hidden_row: 1]

  require Logger

  alias Vutuv.Accounts.User
  alias Vutuv.Activity
  alias Vutuv.Engagement
  alias Vutuv.Fediverse.Actor
  alias Vutuv.Fediverse.BlockedInstance
  alias Vutuv.Fediverse.Deliverer
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.DeliveryFailure
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.Follower
  alias Vutuv.Fediverse.FollowerPrune
  alias Vutuv.Fediverse.HttpSignature
  alias Vutuv.Fediverse.Keys
  alias Vutuv.Fediverse.Media
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.NoteEvent
  alias Vutuv.Fediverse.PostDelivery
  alias Vutuv.Fediverse.PostLike
  alias Vutuv.Fediverse.Reaction
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteFollow
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Pages
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostDenial
  alias Vutuv.Posts.PostRemoteReply
  alias Vutuv.RateLimiter
  alias Vutuv.RemoteHtml
  alias Vutuv.RemoteMedia
  alias Vutuv.Repo
  alias Vutuv.SearchText
  alias Vutuv.SocialFeed.Http
  alias Vutuv.UUIDv7
  alias VutuvWeb.Fediverse.Docs

  @max_attempts 8
  @max_body_bytes 500_000

  # The window every per-member and per-server budget here is measured over —
  # the inbound caps, the outbound reply budget, the remote-follow budget. One
  # hour throughout, so "how much may happen before this bites" is one question
  # with one answer rather than three.
  @inbound_window_ms :timer.hours(1)

  # Inbound replies (issues #1069 and #1071). Six months is the hard ceiling a
  # confirmed-live note pushes forward and nothing else does; a week is how
  # stale a copy may get before its origin is asked again. Both are
  # per-installation knobs (see `note_retention_days/0`), because "how long may
  # we hold a stranger's words" is a call an operator has to be able to make.
  @note_retention_days 183
  @note_refresh_days 7
  # How many remote replies one member may report per day. Deleting a cached
  # copy is cheap and reversible only for its author, so the lever stays open —
  # but not unlimited, or wiping every answer under somebody's post is free.
  @note_report_limit 20

  # Every spelling of the public collection that servers use in the wild. A note
  # is public if one of these is addressed, and private otherwise — including
  # when we cannot tell.
  @public_collections [
    "https://www.w3.org/ns/activitystreams#Public",
    "as:Public",
    "Public"
  ]

  # An actor's followers collection is conventionally its actor URI plus this,
  # and there is no other way to recognise one from the address alone. Named
  # beside the public collections because it is the same kind of fact: a
  # well-known collection URI whose spelling the audience readers depend on.
  @followers_suffix "/followers"

  @doc "The installation-wide switch (FEDIVERSE_ENABLED; off = no endpoints, no deliveries)."
  def enabled?, do: Application.get_env(:vutuv, :fediverse_enabled, true)

  @doc """
  Whether this member takes part: the global switch, their opt-in, a
  confirmed address and an account in good standing (a frozen, suspended or
  deactivated profile is hidden on vutuv, so it must not keep federating).
  """
  def federated?(%User{} = user) do
    enabled?() and user.fediverse_followers? and user.email_confirmed? and
      is_nil(user.frozen_at) and is_nil(user.deactivated_at) and not suspended?(user)
  end

  defp suspended?(%User{suspended_until: nil}), do: false

  defp suspended?(%User{suspended_until: until}),
    do: NaiveDateTime.compare(until, NaiveDateTime.utc_now()) == :gt

  @doc """
  Whether a **revocation** for this member may still leave the building: the
  switch is on and they have an actor, i.e. they took part at some point, so
  copies of their posts may be sitting on other servers.

  Deliberately **not** `federated?/1` (issue #1102). Every takedown path runs at
  the exact moment the post or the account is hidden here — frozen, suspended,
  deactivated — which is precisely when `federated?/1` turns false. Gating a
  revocation on it would mean the only activities that never go out are the ones
  asking other servers to remove something.

  For the same reason it ignores `moved?/1`: a member who redirected their
  Fediverse followers elsewhere stopped *publishing*, but the servers that
  followed them still hold everything published before the move.
  """
  def ever_federated?(%User{} = user), do: enabled?() and get_actor(user) != nil

  ## Actors

  @doc "The member's actor (keypair), created on first use. Race-safe."
  def ensure_actor(%User{} = user) do
    case get_actor(user) do
      nil ->
        {private_pem, public_pem} = Keys.generate()

        %Actor{user_id: user.id, private_key_pem: private_pem, public_key_pem: public_pem}
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id])

        {:ok, get_actor(user)}

      actor ->
        {:ok, actor}
    end
  end

  def get_actor(%User{id: user_id}), do: Repo.get_by(Actor, user_id: user_id)

  ## Remote followers

  # The host of an actor / inbox URI, as SQL: lowercased, scheme and path and
  # port stripped, so it can be compared with a `fediverse_blocked_instances`
  # row. Kept as one macro because the follower browser's server column, three
  # deletes and the admin volume list all need the same expression. NOTE: an
  # Ecto `fragment/1` string may not contain a literal `?` (it is the parameter
  # marker), which is why the pattern uses no non-capturing groups.
  defmacrop uri_host(uri) do
    quote do
      fragment("lower(substring(? from '^[a-z]+://([^/:#]+)'))", unquote(uri))
    end
  end

  # What the follower browser's Account column shows, as SQL — the display
  # name, else the handle, else the actor URI — so sorting that column matches
  # reading it. Never null, so it needs no nulls-last dance.
  defmacrop account_label(follower) do
    quote do
      fragment(
        "lower(coalesce(nullif(?, ''), ?, ?))",
        unquote(follower).name,
        unquote(follower).handle,
        unquote(follower).actor_uri
      )
    end
  end

  @doc """
  Records a remote follower (idempotent per remote actor). A repeat Follow
  re-syncs every cached field from the actor document, the display ones
  included — a remote who renamed must not stay listed under the old handle.

  Subject to the inbound caps (issue #1067): a follower row is a stored inbound
  row, so a server trying to plant thousands of them in an hour is throttled
  with `{:error, :inbound_capped}`.
  """
  def add_follower(%User{} = user, attrs) do
    with :ok <- check_inbound_cap(attrs[:actor_uri] || attrs["actor_uri"]) do
      %Follower{user_id: user.id}
      |> Follower.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:inbox_uri, :shared_inbox_uri, :handle, :name, :updated_at]},
        conflict_target: [:user_id, :actor_uri]
      )
    end
  end

  @doc """
  Re-syncs an existing follower row from the remote actor document (the
  inbox's `Update` handler). A no-op when that actor follows nobody here: an
  `Update` is a broadcast, not a follow request, so it must never mint a row.
  Like `add_follower/2` it swallows a rejected changeset — a hostile actor
  document must not crash the inbox.
  """
  def refresh_follower(%User{id: user_id}, %{actor_uri: actor_uri} = attrs) do
    if follower = Repo.get_by(Follower, user_id: user_id, actor_uri: actor_uri) do
      follower |> Follower.changeset(attrs) |> Repo.update()
    end

    :ok
  end

  def remove_follower(%User{id: user_id}, actor_uri) do
    Repo.delete_all(
      from(f in Follower, where: f.user_id == ^user_id and f.actor_uri == ^actor_uri)
    )

    :ok
  end

  def follower_count(%User{id: user_id}) do
    Repo.aggregate(from(f in Follower, where: f.user_id == ^user_id), :count)
  end

  @doc """
  Drops every remote follower stored for a member — what switching the opt-in
  off means, the same way `drop_reactions/1` answers the reactions switch.

  Two reasons it is a deletion rather than a pause. The rows are stored data
  about people who never signed up here, so "off" has to mean off; and once the
  actor answers `410 Gone` (see `departed?/1`) the remote servers drop the
  follow at their end anyway, so keeping the rows would only inflate the
  member's count with relationships that no longer exist anywhere else.
  """
  def drop_followers(%User{id: user_id}) do
    {count, _} = Repo.delete_all(from(f in Follower, where: f.user_id == ^user_id))
    count
  end

  @doc """
  Whether this member's ActivityPub actor is **gone** rather than merely
  absent: they took part once (the keypair from their opt-in is still here) and
  have since switched the opt-in off.

  This is the difference between `410 Gone` and `404 Not Found` on the actor
  endpoints, and it matters more than the status code suggests: Mastodon & co.
  read a `410` on an actor they know as "this account was deleted" and purge the
  account **and its copies of that account's posts**, while a `404` is treated
  as a hiccup and the copies stay. So `410` is the closest thing the protocol
  offers to "please forget me", and it is reserved for the one case where the
  member actually asked for it.

  Deliberately **not** gone: a member who never federated (nothing to forget), a
  member the installation switch turned off (an operator decision must not
  erase members' remote presence), and every *temporary* state — frozen,
  suspended, deactivated, unconfirmed. Those keep answering `404`, because a
  three-day suspension must never tell the network to delete the account.
  """
  def departed?(%User{} = user) do
    enabled?() and not user.fediverse_followers? and get_actor(user) != nil
  end

  @doc """
  A member's remote followers, newest first, for their own settings page (the
  public followers collection stays count-only, so this owner-only view is the
  only place the list is shown). Capped — a member with a huge following sees
  the most recent `limit`, the exact total comes from `follower_count/1`.
  """
  def list_followers(%User{id: user_id}, limit \\ 50) do
    Repo.all(
      from(f in Follower,
        where: f.user_id == ^user_id,
        order_by: [desc: f.id],
        limit: ^limit
      )
    )
  end

  ## The member's follower browser (/settings/fediverse/followers)

  # A flat list stops working long before a popular account's follower count
  # does, so the owner's full list is a searched, filtered, sorted, paginated
  # table (`VutuvWeb.FediverseFollowersLive`) built on the functions below.
  # Everything is scoped to the member's own rows first, so the work is bounded
  # by their following, not by the installation's.
  #
  # The page size, the sortable column names and the param normalization are
  # deliberately **shared** with the mirror-image browser of the accounts a
  # member follows out there (`VutuvWeb.FediverseFollowingLive`, issue #1160):
  # both are the same table of the same relationship read from opposite ends,
  # so a `?sort=` value has to mean the same thing on either page.
  @browse_per_page 50

  # The sortable columns, by the `?sort=` value a header button sets. None of
  # them is a plain column: "account" sorts by what the row actually shows
  # (display name, else handle, else the actor URI), "server" by the host
  # inside the actor URI.
  @browse_sort_columns ~w(account server followed)

  # The column a browser sorts by until somebody clicks a header. Named once
  # here because the URL builder (`VutuvWeb.BrowseTable`) has to leave it out of
  # a shareable link, and a second literal there would drift.
  @browse_default_sort "followed"

  # How many servers the filter dropdown offers. Beyond that the free-text
  # search is the way in - a select with 400 entries is not a filter.
  @browse_host_choices 30

  @doc "The browser page size, shared by the queries and the pagers."
  def browse_per_page, do: @browse_per_page

  @doc "The sortable browser columns (the `?sort=` values)."
  def browse_sort_columns, do: @browse_sort_columns

  @doc "The column a browser sorts by when the URL names none."
  def browse_default_sort, do: @browse_default_sort

  @doc """
  Normalizes raw request params into a validated filter map for either Fediverse
  browser: `q` (free-text search, trimmed), `server` (an exact host, lowercased),
  `sort` (a known column, default "followed") and `dir` ("asc"/"desc", default
  per column - newest first for the date, A-Z for the text columns). Anything
  invalid falls back to a safe default, so the params can never reach the query.
  """
  def browse_filters(params) when is_map(params) do
    sort = validated_browse_sort(params["sort"])

    %{
      q: Pages.blank_to_nil(params["q"]),
      server: params["server"] |> Pages.blank_to_nil() |> normalize_browse_server(),
      sort: sort,
      dir: validated_browse_dir(params["dir"]) || browse_default_dir(sort)
    }
  end

  @doc """
  The direction a column sorts in when it is picked for the first time: the
  date newest-first (what a follow list is read for), the text columns A-Z.
  """
  def browse_default_dir(@browse_default_sort), do: "desc"
  def browse_default_dir(_text_column), do: "asc"

  @doc "How many of the member's remote followers match `filters` (for the pager)."
  def count_followers(%User{id: user_id}, filters \\ %{}) do
    user_id |> followers_base(filters) |> Repo.aggregate(:count)
  end

  @doc """
  One page of the member's follower browser: filtered, searched, sorted and
  paginated. `opts` may carry `:total` (skip the recount) and `:per_page`
  (default `browse_per_page/0`).
  """
  def list_followers_page(%User{id: user_id}, filters, params \\ %{}, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, @browse_per_page)
    base = followers_base(user_id, filters)
    total = Keyword.get(opts, :total) || Repo.aggregate(base, :count)

    base
    |> order_followers(filters)
    |> Pages.paginate(params, total, per_page)
    |> Repo.all()
  end

  @doc """
  The servers this member's remote followers live on, biggest first - the
  follower browser's server filter, and the answer to "where are they coming
  from". Capped at `limit` hosts.
  """
  def follower_hosts(%User{id: user_id}, limit \\ @browse_host_choices) do
    Repo.all(
      from(f in Follower,
        where: f.user_id == ^user_id,
        group_by: uri_host(f.actor_uri),
        order_by: [desc: count(f.id), asc: uri_host(f.actor_uri)],
        limit: ^limit,
        select: %{host: uri_host(f.actor_uri), count: count(f.id)}
      )
    )
  end

  defp validated_browse_sort(sort) when sort in @browse_sort_columns, do: sort
  defp validated_browse_sort(_other), do: @browse_default_sort

  defp validated_browse_dir(dir) when dir in ~w(asc desc), do: dir
  defp validated_browse_dir(_other), do: nil

  defp normalize_browse_server(nil), do: nil
  defp normalize_browse_server(host), do: String.downcase(host)

  defp followers_base(user_id, filters) do
    from(f in Follower, where: f.user_id == ^user_id)
    |> filter_follower_server(Map.get(filters, :server))
    |> search_followers(Map.get(filters, :q))
  end

  defp filter_follower_server(query, nil), do: query

  defp filter_follower_server(query, host),
    do: where(query, [f], uri_host(f.actor_uri) == ^host)

  defp search_followers(query, nil), do: query

  defp search_followers(query, term) do
    case browse_search_parts(term) do
      {:handle_and_host, name, host} ->
        where(
          query,
          [f],
          ilike(f.handle, ^name) and ilike(f.actor_uri, ^host)
        )

      {:anywhere, like} ->
        where(
          query,
          [f],
          ilike(f.name, ^like) or ilike(f.handle, ^like) or ilike(f.actor_uri, ^like)
        )
    end
  end

  # How a browse search term is read, shared by both tables so a pasted handle
  # is interpreted the same way on either page: a full "@user@host" is two
  # facts, not one substring - matched against the handle and the server
  # separately, so the address a member copies out of a Mastodon profile finds
  # the row it names. Anything else is one substring, matched anywhere.
  # Both arms come back ready for `ilike/2`.
  defp browse_search_parts(term) do
    case term |> String.trim_leading("@") |> String.split("@", parts: 2) do
      [name, host] when host != "" -> {:handle_and_host, contains(name), contains(host)}
      _one_part -> {:anywhere, contains(term)}
    end
  end

  defp contains(term), do: "%" <> SearchText.escape_like(String.trim_leading(term, "@")) <> "%"

  # The row's own id (UUID v7, so arrival order) is the last key of every sort,
  # so offset pagination stays stable across pages when the visible values tie
  # (two followers from the same server, two accounts with no display name).
  defp order_followers(query, filters) do
    dir = direction(Map.get(filters, :dir))

    case Map.get(filters, :sort) do
      "account" ->
        order_by(query, [f], [{^dir, account_label(f)}, desc: f.id])

      "server" ->
        order_by(query, [f], [{^dir, uri_host(f.actor_uri)}, desc: f.id])

      _followed ->
        # The column the table shows, so the order can never contradict the
        # dates you are reading. `inserted_at` only has second resolution, so
        # the id (UUID v7, arrival order) breaks ties *in the same direction* -
        # a total order, and a burst of follows still pages deterministically.
        order_by(query, [f], [{^dir, f.inserted_at}, {^dir, f.id}])
    end
  end

  defp direction("asc"), do: :asc
  defp direction(_desc), do: :desc

  @doc """
  Installation-wide federation figures for the admin dashboard (issue #843):
  how many members federate, how many remote followers they have between them,
  the outbound delivery-queue depth and how many of those rows are stuck
  (carry a `last_error`), so a broken delivery run is visible at a glance, plus
  how many remote servers the operator has shut out (issue #1067) and how many
  takedowns gave up without arriving (issue #1102).
  """
  def stats do
    %{
      federating_members: federating_member_count(),
      remote_followers: Repo.aggregate(Follower, :count),
      queue_depth: Repo.aggregate(Delivery, :count),
      stuck_deliveries:
        Repo.aggregate(from(d in Delivery, where: not is_nil(d.last_error)), :count),
      blocked_instances: blocked_instance_count(),
      failed_takedowns: delivery_failure_count(),
      # The inbound-following side (issues #1160 and #1161): how many accounts
      # out there members here follow, and how much of what those accounts wrote
      # is currently cached.
      remote_follows: Repo.aggregate(Follow, :count),
      cached_posts: remote_post_total()
    }
  end

  @doc """
  Members in good standing who opted in — the SQL mirror of `federated?/1`.
  The good-standing arm delegates to `Vutuv.Moderation.Query.account_hidden_row/1`
  (the one spelling of frozen/deactivated/suspended), so a changed suspension
  boundary is edited in one place instead of drifting from `federated?/1` here.
  """
  def federating_member_count do
    Repo.aggregate(
      from(u in User,
        where: u.fediverse_followers? and u.email_confirmed? and not account_hidden_row(u)
      ),
      :count
    )
  end

  @doc "How many public posts the member has (the outbox totalItems)."
  def public_post_count(%User{id: user_id}) do
    Repo.aggregate(
      from(p in Post,
        as: :post,
        where: p.user_id == ^user_id,
        where: not exists(from(d in PostDenial, where: d.post_id == parent_as(:post).id))
      ),
      :count
    )
  end

  @doc """
  What the `featured` collection holds (issue #1110): the member's pinned post
  when the **anonymous public** may see it, else nothing. A list, because that
  is the collection's shape — one entry today.

  Anonymous is the right viewer here and not a simplification: the collection
  is served unauthenticated to every remote server, so a pin that is
  restricted, frozen or hidden must be absent from it exactly as it is absent
  from the `.md` sibling of the profile. Preloaded for `Docs.note/2`.
  """
  def featured_posts(%User{} = user) do
    case Posts.pinned_post(user, nil) do
      %Post{} = post -> [Repo.preload(post, Docs.note_preloads())]
      nil -> []
    end
  end

  @doc """
  The distinct inboxes a member's activities go to: one per server where the
  remote declared a sharedInbox (however many followers live there), else the
  per-actor inbox.
  """
  def delivery_inboxes(%User{id: user_id}) do
    Repo.all(
      from(f in Follower,
        where: f.user_id == ^user_id,
        distinct: true,
        select: coalesce(f.shared_inbox_uri, f.inbox_uri)
      )
    )
  end

  @doc """
  The distinct inboxes of the accounts this member **follows** (issue #1160).

  Deliberately separate from `delivery_inboxes/1` and never used for posts: an
  account somebody follows never asked to receive their writing. It exists for
  the one message those servers do have to hear — "this actor is gone" — so a
  deleted or removed member stops being delivered to from the other side too.
  """
  def followed_inboxes(%User{id: user_id}) do
    Repo.all(
      from(f in Follow,
        join: a in RemoteAccount,
        on: a.id == f.remote_account_id,
        where: f.user_id == ^user_id,
        distinct: true,
        select: coalesce(a.shared_inbox_uri, a.inbox_uri)
      )
    )
  end

  ## Following an account on another network (issue #1160)

  # The other direction of the relationship, and the first time a member's own
  # action makes vutuv ask a stranger's server for something ongoing. Three
  # gates bound it, in the order they cost:
  #
  #   * the member must federate at all — the Follow is signed with their own
  #     actor key, so there is no such thing as an actorless follow, and no way
  #     to make this work "just for reading";
  #   * an hourly budget (the `claim_reply_budget/1` pattern), so a compromised
  #     account cannot walk a server's whole member list;
  #   * a total ceiling, because every accepted follow is a standing invitation
  #     for another server to deliver here.
  @max_remote_follows 1_000
  @remote_follow_limit 30

  @doc "How many accounts on other networks one member may follow in total."
  def max_remote_follows,
    do: Application.get_env(:vutuv, :fediverse_max_remote_follows, @max_remote_follows)

  @doc "How many follow requests one member may send per hour."
  def remote_follow_limit,
    do: Application.get_env(:vutuv, :fediverse_remote_follow_limit, @remote_follow_limit)

  @doc """
  A member follows an account on another network: resolve the address, remember
  the account, and send a signed `Follow`.

  `address` is anything people paste — `@you@server`, `you@server`, or a profile
  URL — normalized by `Vutuv.Fediverse.RemoteFollow.parse_address/1` and resolved
  to the account's canonical actor id through WebFinger.

  Returns `{:ok, follow}` with the remote account preloaded, or `{:error, reason}`
  where reason is one of:

    * `:fediverse_disabled` — the installation switch is off.
    * `:not_federating` — the member has not switched Fediverse participation on
      (or their account is not in good standing). **The refusal the member can do
      something about**, which is why it is named separately: the page turns it
      into an explanation and a link to `/settings/fediverse` rather than a dead
      end.
    * `:moved` — the member redirected their Fediverse followers elsewhere, so
      this account no longer acts out there.
    * `:invalid_address` / `:unreachable` / `:no_actor` — from the address parse
      and the WebFinger lookup (`RemoteFollow`).
    * `:local_account` — the address names a member of this very installation.
      Following them is a vutuv follow, not a Fediverse one, and saying so is far
      more useful than a signed request to ourselves.
    * `:instance_blocked` — the operator shut that server out.
    * `:follow_capped` — the hourly budget is spent.
    * `:follow_limit` — the member is at `max_remote_follows/0`.
    * `:already_following` — there is a row for this pair already.
    * `:unreachable_actor` — WebFinger answered but the actor document did not.

  The state the row starts in is `requested`, because that is the truth: an
  account that approves its followers by hand may never answer, and a page that
  showed "Following" for a request nobody accepted would be lying.
  """
  def follow_remote(%User{} = user, address) do
    with :ok <- check_can_follow(user),
         :ok <- check_follow_limit(user),
         {:ok, account} <- resolve_remote_account(user, address),
         {:ok, follow} <- insert_remote_follow(user, account) do
      enqueue(
        user,
        [account.inbox_uri],
        Docs.follow_activity(user, account.actor_uri, follow.follow_activity_id)
      )

      {:ok, %{follow | remote_account: account}}
    end
  end

  @doc """
  Looks an address up and remembers the account behind it, **without** following
  it (issue #1162): the half of `follow_remote/2` that answers "who is this",
  which is the question somebody has before they decide.

  Deliberately does **not** require the member to federate. Following needs their
  own actor key to sign the request; looking somebody up does not, and requiring
  it would be a chicken-and-egg — the account page is where a member who has not
  switched participation on finds out what they would be switching it on for.
  The fetch is then signed anonymously, which a few authorized-fetch servers
  refuse; that is a worse answer for those accounts, not a wrong one.

  Every other gate still holds, in the same order and for the same reasons: the
  installation switch, the operator blocklist on each of the three hosts a
  lookup passes through, an address on this installation, and the hourly budget
  — this is a member-triggered outbound request either way.

  Returns `{:ok, account}` or the same `{:error, reason}` vocabulary
  `follow_remote/2` speaks.
  """
  def resolve_remote_account(%User{} = user, address) do
    with :ok <- check_can_resolve(),
         {:ok, {_name, host}} <- RemoteFollow.parse_address(address),
         :ok <- check_follow_host(host),
         :ok <- claim_remote_follow_budget(user),
         {:ok, actor_uri} <- RemoteFollow.resolve_actor(address),
         :ok <- check_follow_host(actor_uri),
         {:ok, remote} <- fetch_follow_target(actor_uri, user),
         :ok <- check_follow_host(remote.id) do
      upsert_remote_account(remote)
    end
  end

  @doc """
  Remembers an account we have just stored something from — a reply under a
  member's post, or a reaction to one (issue #1162).

  It costs no request: the inbox has already fetched and verified that actor
  document in order to check the signature, so this is only a matter of keeping
  what it read. What it buys is that every remote handle vutuv shows has an
  internal destination, instead of a bare link out of the site to somebody the
  reader cannot decide about.

  Called only after something from that actor was really stored, so a stranger's
  activity cannot plant account rows; and the rows go again by themselves once
  nothing references them (`purge_unreferenced_remote_accounts/0`).
  """
  def remember_remote_account(%{id: actor_uri} = remote) when is_binary(actor_uri) do
    if enabled?(), do: upsert_remote_account(remote)
    :ok
  end

  def remember_remote_account(_remote), do: :ok

  @doc "One stored remote account by row id, or nil."
  def get_remote_account(id), do: UUIDv7.with_cast(id, &Repo.get(RemoteAccount, &1))

  @doc """
  The member takes the follow back: a best-effort `Undo(Follow)` to the other
  server, then the row goes.

  The row is deleted whether or not the Undo can be sent, because it describes
  *our* member's intent and they have withdrawn it; a server that never hears
  about it simply stops being followed the moment we stop accepting its
  deliveries.
  """
  def unfollow_remote(%User{} = user, follow_id) do
    case get_remote_follow(user, follow_id) do
      nil ->
        {:error, :not_found}

      follow ->
        undo_remote_follow(user, follow)
        Repo.delete(follow)
        # The cached posts existed because somebody here followed the author
        # (issue #1161). If nobody does any more, they go now rather than at the
        # next sweep.
        purge_unfollowed_remote_posts([follow.remote_account_id])
        :ok
    end
  end

  @doc """
  Mutes (or unmutes) the member's follow of one remote account.

  The same meaning a local follow's mute has: the subscription stays, its posts
  leave the feed. It is the private, reversible answer to "not this account
  today" — and having it matters because the only other lever on a cached post
  is a report, which deletes the one shared copy for **every** member following
  that author.

  Scoped to the member's own follow, so an account id from anywhere resolves to
  nothing but their own row. Returns `:ok` either way — muting something you do
  not follow is not an error worth a message.
  """
  def set_remote_follow_mute(%User{id: user_id}, remote_account_id, muted?) do
    UUIDv7.with_cast(remote_account_id, fn account_id ->
      Repo.update_all(
        from(f in Follow, where: f.user_id == ^user_id and f.remote_account_id == ^account_id),
        set: [muted: muted?, updated_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)]
      )
    end)

    :ok
  end

  @doc """
  *Why* this member cannot follow anybody out there, when they cannot: `nil`
  when they can, else `:opted_out`, `:restricted` or `:disabled`.

  `federated?/1` is one boolean over four very different situations, and the
  difference decides which sentence is true and which link helps. Telling a
  member the moderation freezer is holding to go and flip a switch they already
  flipped, and pointing them at a page that shows it on, is exactly the wrong
  answer in the one place clarity matters most.

  Shared by every page that offers a follow (`/settings/fediverse/following`
  and the account page), so the four situations cannot be told apart on one and
  collapsed on the other.
  """
  def follow_refusal(%User{} = user) do
    cond do
      not enabled?() -> :disabled
      Vutuv.Moderation.account_hidden?(user) -> :restricted
      not user.fediverse_followers? or not user.email_confirmed? -> :opted_out
      # A member who redirected their Fediverse followers elsewhere: this
      # account no longer acts out there at all, so a live Follow button would
      # be a promise `check_can_follow/1` then refuses. Listed last because it
      # is the only one of the four that a *federating* member can be in.
      moved?(user) -> :moved
      true -> nil
    end
  end

  @doc """
  The member's follow of one remote account, or nil — what the account page's
  button branches on.
  """
  def remote_follow_for(%User{id: user_id}, %RemoteAccount{id: account_id}) do
    Repo.get_by(Follow, user_id: user_id, remote_account_id: account_id)
  end

  @doc """
  One of the member's own follows, with the remote account preloaded, or nil.
  Scoped to the member, so an id from somebody else's page resolves to nothing.
  """
  def get_remote_follow(%User{id: user_id}, follow_id) do
    UUIDv7.with_cast(follow_id, fn id ->
      Repo.one(
        from(f in Follow,
          where: f.id == ^id and f.user_id == ^user_id,
          preload: [:remote_account]
        )
      )
    end)
  end

  @doc """
  The other server said yes (`Accept(Follow)`): the follow is live.

  Scoped to the actor that answered, so one server can never seal a follow
  addressed to another. Idempotent — a redelivered `Accept` writes the same
  state again.
  """
  def accept_remote_follow(%User{} = user, activity, actor_uri) do
    if follow = find_answered_follow(user, activity, actor_uri) do
      follow |> Follow.accept() |> Repo.update()
    end

    :ok
  end

  @doc """
  The other server said no (`Reject(Follow)`): the row goes.

  Deliberately a deletion rather than a third state. There is nothing left to
  show and nothing to retry, and keeping a stranger's refusal on file about a
  member earns nobody anything. The member sees the account disappear from their
  list, which is what "they did not accept" looks like.
  """
  def reject_remote_follow(%User{} = user, activity, actor_uri) do
    if follow = find_answered_follow(user, activity, actor_uri), do: Repo.delete(follow)

    :ok
  end

  @doc """
  How many accounts on other networks this member follows, whatever state the
  follow is in — the figure their own settings page shows, because a request
  they sent is a thing they did.
  """
  def remote_follow_count(%User{id: user_id}) do
    Repo.aggregate(from(f in Follow, where: f.user_id == ^user_id), :count)
  end

  @doc """
  How many of those follows the other side has confirmed — the `totalItems` of
  the count-only `following` collection. Only accepted ones: a request nobody
  answered is not a relationship, and publishing it would leak what a member
  tried to do.
  """
  def accepted_follow_count(%User{id: user_id}) do
    Repo.aggregate(
      from(f in Follow, where: f.user_id == ^user_id and f.state == "accepted"),
      :count
    )
  end

  @doc """
  Drops every follow of a remote account this member holds, asking each server
  to forget it first — what switching federation off means for this direction,
  the mirror of `drop_followers/1`.

  Returns how many rows went.
  """
  def drop_remote_follows(%User{} = user) do
    follows = list_remote_follows(user)
    undo_remote_follows(user, follows)
    # Their likes are the other half of "the rows about people on other
    # networks, in both directions" (issue #1164). Withdrawn before the follows
    # go, and unconditionally: a like of an account somebody else here still
    # follows would otherwise survive this member leaving, as a record of what
    # they read on another network kept after they asked to be out of it.
    drop_remote_likes(user)

    {count, _} = Repo.delete_all(from(f in Follow, where: f.user_id == ^user.id))
    # Their cached posts existed because this member followed their authors
    # (issue #1161); for the ones nobody else here follows, that reason is gone.
    purge_unfollowed_remote_posts(Enum.map(follows, & &1.remote_account_id))
    count
  end

  @doc """
  Every remote post this member likes, as `{post, account}` — for their GDPR
  export and for the withdrawal below, which needs the same two rows.
  """
  def list_remote_likes(%User{id: user_id}) do
    Repo.all(
      from(l in PostLike,
        join: p in RemotePost,
        on: p.id == l.remote_post_id,
        join: a in RemoteAccount,
        on: a.id == p.remote_account_id,
        where: l.user_id == ^user_id,
        order_by: [desc: l.id],
        select: {p, a}
      )
    )
  end

  @doc """
  Withdraws every like this member holds on posts from other networks and drops
  the markers: an `Undo(Like)` per post, then the rows.

  Called when they leave the Fediverse, so what stands on other servers under
  their name goes with the decision rather than after it.
  """
  def drop_remote_likes(%User{} = user) do
    posts = list_remote_likes(user)

    Enum.each(posts, fn {post, account} ->
      deliver_like(user, %{post | remote_account: account}, &Docs.undo_like_activity/3)
    end)

    {count, _} = Repo.delete_all(from(l in PostLike, where: l.user_id == ^user.id))
    count
  end

  @doc "How many of the member's remote follows match `filters` (for the pager)."
  def count_remote_follows(%User{id: user_id}, filters \\ %{}) do
    user_id |> remote_follows_base(filters) |> Repo.aggregate(:count)
  end

  @doc """
  One page of the member's following browser: filtered, searched, sorted and
  paginated, with the remote account preloaded. `opts` may carry `:total` (skip
  the recount) and `:per_page` (default `browse_per_page/0`).
  """
  def list_remote_follows_page(%User{id: user_id}, filters, params \\ %{}, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, @browse_per_page)
    base = remote_follows_base(user_id, filters)
    total = Keyword.get(opts, :total) || Repo.aggregate(base, :count)

    base
    |> order_remote_follows(filters)
    |> with_remote_account()
    |> Pages.paginate(params, total, per_page)
    |> Repo.all()
  end

  @doc """
  Every follow this member holds, account preloaded and in no particular order —
  the whole set rather than a page of it, for the GDPR export.
  """
  def list_remote_follows(%User{id: user_id}) do
    user_id |> remote_follows_base(%{}) |> with_remote_account() |> Repo.all()
  end

  # The account is already joined and scanned by `remote_follows_base/2`, so the
  # preload rides that binding instead of costing a second `WHERE id IN (…)`.
  # Attached here and not in the base, because `count_remote_follows/2`
  # aggregates the same query and has no use for it.
  defp with_remote_account(query), do: preload(query, [account: a], remote_account: a)

  @doc """
  The servers this member follows accounts on, biggest first — the following
  browser's server filter. Capped at `limit` hosts.
  """
  def remote_follow_hosts(%User{id: user_id}, limit \\ @browse_host_choices) do
    Repo.all(
      from(f in Follow,
        join: a in RemoteAccount,
        on: a.id == f.remote_account_id,
        where: f.user_id == ^user_id,
        group_by: a.host,
        order_by: [desc: count(f.id), asc: a.host],
        limit: ^limit,
        select: %{host: a.host, count: count(f.id)}
      )
    )
  end

  @doc """
  Every member here who follows this remote account, whatever state the follow
  is in — who an activity from that account concerns.
  """
  def remote_follow_users(actor_uri) when is_binary(actor_uri) do
    Repo.all(
      from(f in Follow,
        join: a in RemoteAccount,
        on: a.id == f.remote_account_id,
        join: u in User,
        on: u.id == f.user_id,
        where: a.actor_uri == ^actor_uri,
        distinct: true,
        select: u
      )
    )
  end

  def remote_follow_users(_actor_uri), do: []

  @doc """
  Re-syncs a stored remote account from a freshly fetched actor document (the
  inbox's `Update` handler). A no-op for an account nobody here follows: an
  `Update` is a broadcast, not a request, so it must never mint a row.
  """
  def refresh_remote_account(%{id: actor_uri} = remote) when is_binary(actor_uri) do
    with %RemoteAccount{} = account <- Repo.get_by(RemoteAccount, actor_uri: actor_uri),
         # A rejected changeset is swallowed, like `refresh_follower/2` swallows
         # its own: a hostile actor document must not crash the inbox, and only
         # some of what it carries is truncated on the way in (an over-long key
         # or self-description is the changeset's to refuse, quietly).
         {:ok, account} <-
           account |> RemoteAccount.changeset(remote_account_attrs(remote)) |> Repo.update() do
      # An actor `Update` is exactly when a picture changes, and the fetch is
      # a no-op when the URL is the one already stored (issue #1163).
      Media.fetch_avatar_async(account, remote[:icon])
    end

    :ok
  end

  def refresh_remote_account(_remote), do: :ok

  @doc """
  The remote account deleted itself (`Delete` of its own actor): drop the row,
  and with it — through the cascade — everybody's follow of it.

  Nothing is sent back. The account is gone, so an `Undo(Follow)` would be a
  POST into a void; and the member's list simply stops showing somebody who no
  longer exists, which is exactly what happened.
  """
  def remove_remote_account(actor_uri) when is_binary(actor_uri) do
    accounts = from(a in RemoteAccount, where: a.actor_uri == ^actor_uri)

    # The rows cascade, the files do not: the account's own picture and every
    # picture on the posts we cached for it have to be swept before the delete
    # takes away the ids that name them.
    wipe_media(
      from(p in RemotePost, join: a in ^subquery(accounts), on: p.remote_account_id == a.id)
    )

    wipe_avatars(accounts)
    Repo.delete_all(accounts)
    :ok
  end

  def remove_remote_account(_actor_uri), do: :ok

  # ── The gates, cheapest first ──────────────────────────────────────────────

  # Following is looking somebody up plus an identity of one's own, so it is
  # written that way: the installation switch is asserted once, where a lookup
  # asserts it, instead of restated here where the two could drift apart.
  defp check_can_follow(%User{} = user) do
    with :ok <- check_can_resolve() do
      cond do
        not federated?(user) -> {:error, :not_federating}
        moved?(user) -> {:error, :moved}
        true -> :ok
      end
    end
  end

  defp check_can_resolve do
    if enabled?(), do: :ok, else: {:error, :fediverse_disabled}
  end

  # A block is both ears and mouth shut, and this is the mouth. Checked three
  # times on one follow — on the typed host, on the resolved actor URL and on
  # the canonical id the document claims — because each hop can land somewhere
  # else than the last.
  defp check_follow_host(uri) do
    cond do
      instance_blocked?(uri) -> {:error, :instance_blocked}
      local_host?(uri) -> {:error, :local_account}
      true -> :ok
    end
  end

  @doc """
  Whether `uri` (an actor id, a bare host, a `@user@host` address) lives on this
  very installation. Public because more than the follow gate has to know: the
  search page offers "follow this account" only for an address that is really
  somewhere else, and the two must answer the same way or the page offers
  something `follow_remote/2` then refuses.

  Following a vutuv member is a vutuv follow; saying so beats signing a request
  to ourselves and waiting for an Accept that our own inbox would have to
  invent.
  """
  def local_host?(uri) do
    case BlockedInstance.normalize_host(uri) do
      nil -> false
      host -> host == String.downcase(VutuvWeb.Endpoint.host())
    end
  end

  defp claim_remote_follow_budget(%User{id: user_id}) do
    case RateLimiter.hit(
           {:fediverse_remote_follow, user_id},
           remote_follow_limit(),
           @inbound_window_ms
         ) do
      :ok -> :ok
      _ -> {:error, :follow_capped}
    end
  end

  defp check_follow_limit(%User{} = user) do
    if remote_follow_count(user) >= max_remote_follows(),
      do: {:error, :follow_limit},
      else: :ok
  end

  # Signed with the member's own key: instances in authorized-fetch mode refuse
  # an anonymous GET, and this is the one fetch we make on their behalf.
  defp fetch_follow_target(actor_uri, %User{} = user) do
    case fetch_remote_actor(actor_uri, signer(user)) do
      {:ok, remote} -> {:ok, remote}
      _error -> {:error, :unreachable_actor}
    end
  end

  # ── Storage ───────────────────────────────────────────────────────────────

  # Columns an upsert must NOT touch, beyond the identity ones. The avatar three
  # (issue #1163) are ours, not the actor document's: the document names a URL,
  # we then fetch it, store a fingerprinted file and let the AI gate rule on it,
  # all of it long after this write. `{:replace_all_except, …}` sets every other
  # column from the INSERT, and these are absent from it — so leaving them out
  # of this list would null a stored, approved picture on every repeat resolve.
  @remote_account_keep [
    :id,
    :actor_uri,
    :inserted_at,
    :avatar,
    :avatar_moderation,
    :avatar_source
  ]

  defp upsert_remote_account(remote) do
    attrs = remote_account_attrs(remote)

    result =
      %RemoteAccount{}
      |> RemoteAccount.changeset(attrs)
      |> Repo.insert(
        # Everything the actor document really carries is re-synced, named as
        # "all but what is ours" rather than as an allowlist: a column added
        # later must refresh on a repeat follow too, and a hand-maintained list
        # is exactly what silently stops doing that.
        on_conflict: {:replace_all_except, @remote_account_keep},
        conflict_target: [:actor_uri],
        # The id is minted in Elixir (UUID v7), so on a conflict the struct
        # would otherwise carry the id of the row that was NOT written. Reading
        # it back is what makes the follow point at the account that exists.
        returning: [:id]
      )

    with {:ok, account} <- result do
      Media.fetch_avatar_async(account, remote[:icon])
      {:ok, account}
    end
  end

  defp remote_account_attrs(remote) do
    %{
      actor_uri: remote.id,
      host: BlockedInstance.normalize_host(remote.id) || "unknown",
      handle: remote.preferred_username,
      name: remote.name,
      # The self-description is remote HTML, so it is reduced to text like every
      # other stranger's words here; nothing they write is ever rendered raw.
      summary: remote_text(remote.summary, RemoteAccount.max_summary()),
      inbox_uri: remote.inbox,
      shared_inbox_uri: remote.shared_inbox,
      public_key_id: remote.public_key_id,
      public_key_pem: remote.public_key_pem,
      refreshed_at: DateTime.utc_now(:second)
    }
  end

  defp insert_remote_follow(%User{} = user, %RemoteAccount{} = account) do
    # The activity id names the row, so the id is minted before the insert
    # rather than read back after it: an `Accept` finds its follow by this
    # string and by nothing else.
    id = UUIDv7.generate()

    %Follow{id: id, user_id: user.id, remote_account_id: account.id}
    |> Follow.changeset(%{
      state: "requested",
      follow_activity_id: Docs.follow_activity_id(user, id)
    })
    |> Repo.insert()
    |> case do
      {:ok, follow} -> {:ok, follow}
      {:error, _changeset} -> {:error, :already_following}
    end
  end

  defp undo_remote_follow(%User{} = user, %Follow{} = follow),
    do: undo_remote_follows(user, [follow])

  # Best effort, and deliberately gated on `ever_federated?/1` rather than
  # `federated?/1`: switching federation off is exactly when every follow is
  # withdrawn, and that is precisely when `federated?/1` turns false — the same
  # trap `revoke_post/1` documents.
  #
  # Takes the whole list rather than one row at a time because leaving the
  # Fediverse withdraws every follow at once: asked per row, the actor lookup
  # and the blocklist check would each run once per followed account (two
  # queries per row, up to `max_remote_follows/0` of them) and each withdrawal
  # would be its own single-row insert.
  defp undo_remote_follows(_user, []), do: :ok

  defp undo_remote_follows(%User{} = user, follows) do
    if enabled?() and ever_federated?(user) do
      blocked = blocked_hosts()

      follows
      |> Enum.filter(&deliverable_undo?(&1, blocked))
      |> Enum.map(fn %Follow{remote_account: account} = follow ->
        {account.inbox_uri,
         Docs.undo_follow_activity(user, account.actor_uri, follow.follow_activity_id)}
      end)
      |> enqueue_each(user)
    end

    :ok
  end

  defp deliverable_undo?(%Follow{remote_account: %RemoteAccount{} = account}, blocked) do
    not MapSet.member?(blocked, BlockedInstance.normalize_host(account.actor_uri))
  end

  defp deliverable_undo?(_follow, _blocked), do: false

  defp blocked_hosts do
    Repo.all(from(b in BlockedInstance, select: b.host)) |> MapSet.new()
  end

  # The follow an `Accept`/`Reject` answers. Primarily by the activity id we
  # minted and the other server echoed back; failing that (servers differ in how
  # faithfully they echo a Follow) by the pair, which is just as safe because
  # both arms are scoped to the actor that answered.
  defp find_answered_follow(%User{id: user_id}, activity, actor_uri) when is_binary(actor_uri) do
    base =
      from(f in Follow,
        join: a in RemoteAccount,
        on: a.id == f.remote_account_id,
        where: f.user_id == ^user_id and a.actor_uri == ^actor_uri
      )

    case activity_object_id(activity["object"]) do
      id when is_binary(id) ->
        Repo.one(from(f in base, where: f.follow_activity_id == ^id)) || Repo.one(base)

      _ ->
        Repo.one(base)
    end
  end

  defp find_answered_follow(_user, _activity, _actor_uri), do: nil

  # ── The following browser (/settings/fediverse/following) ─────────────────

  defp remote_follows_base(user_id, filters) do
    from(f in Follow,
      join: a in RemoteAccount,
      as: :account,
      on: a.id == f.remote_account_id,
      where: f.user_id == ^user_id
    )
    |> filter_follow_server(Map.get(filters, :server))
    |> search_remote_follows(Map.get(filters, :q))
  end

  defp filter_follow_server(query, nil), do: query

  defp filter_follow_server(query, host),
    do: where(query, [account: a], a.host == ^host)

  defp search_remote_follows(query, nil), do: query

  defp search_remote_follows(query, term) do
    case browse_search_parts(term) do
      {:handle_and_host, name, host} ->
        where(
          query,
          [account: a],
          ilike(a.handle, ^name) and ilike(a.host, ^host)
        )

      {:anywhere, like} ->
        where(
          query,
          [account: a],
          ilike(a.name, ^like) or ilike(a.handle, ^like) or ilike(a.actor_uri, ^like)
        )
    end
  end

  # Same three sorts the follower browser offers, so a `?sort=` value means the
  # same thing on both pages; the row's own id (UUID v7, arrival order) is the
  # last key everywhere, so paging stays stable when the visible values tie.
  defp order_remote_follows(query, filters) do
    dir = direction(Map.get(filters, :dir))

    case Map.get(filters, :sort) do
      "account" ->
        order_by(query, [f, account: a], [{^dir, account_label(a)}, desc: f.id])

      "server" ->
        order_by(query, [f, account: a], [{^dir, a.host}, desc: f.id])

      _followed ->
        order_by(query, [f], [{^dir, f.inserted_at}, {^dir, f.id}])
    end
  end

  ## What the followed accounts post (issue #1161)

  # The other half of following somebody out there: their posts, cached so they
  # can appear in the follower's home feed.
  #
  # The whole design is "bounded copy". An author publishing to their followers
  # chose exactly this delivery — their server pushes each post to every
  # follower's server — but consent from somebody who never signed up here is
  # not obtainable, so what we keep is bounded instead: plain text only, six
  # months at the very most, an upstream `Delete` honoured at once, and gone the
  # moment the last member here stops following them.
  @remote_post_retention_days 183

  # How many cached posts one member may report per day. Same lever and same
  # reasoning as the reply reports: deleting a cached copy costs its author
  # nothing they did not keep, so the lever stays open — but not unlimited, or
  # wiping a whole account's stream is free.
  @remote_post_report_limit 20

  @doc "How long a cached post from a followed account may live (days)."
  def remote_post_retention_days,
    do: Application.get_env(:vutuv, :fediverse_post_retention_days, @remote_post_retention_days)

  @doc "How many cached posts one member may report per day."
  def remote_post_report_limit, do: @remote_post_report_limit

  @doc """
  Stores a post a followed account published (`Create(Note)` / `Create(Question)`).

  Deliberately **installation-wide and idempotent**, not per member: several
  members can follow the same account, and it is the same post. The unique
  `object_uri` is what makes a redelivery (one per follower, until every server
  uses our shared inbox) store one row.

  Every gate, in order: the installation switch, at least one **accepted** local
  follow of the sending actor, the object really is a Note or a Question, the
  audience is one somebody here was published to, the sending server is within
  its inbound cap, the post is not a reply into somebody else's conversation,
  and there is text left once the markup is gone.

  Returns `:ok` or `:skip`; the inbox answers 202 either way, so a misdirected
  activity never learns which gate it failed. A redelivery of a post we already
  hold is a `:skip` — the row is already there and so are its pictures.
  """
  def record_remote_post(activity, actor_uri) when is_binary(actor_uri) do
    with true <- enabled?(),
         %RemoteAccount{} = account <- followed_account(actor_uri),
         %{} = object <- remote_post_object(activity["object"]),
         audience when is_binary(audience) <- remote_post_audience(object, activity),
         :ok <- check_inbound_cap(actor_uri),
         true <- own_thread?(object, account),
         {:ok, post} <- insert_remote_post(account, object, audience) do
      attach_pictures(post, object)
      :ok
    else
      _ -> :skip
    end
  end

  def record_remote_post(_activity, _actor_uri), do: :skip

  # The post's pictures (issue #1163): recorded here, downloaded afterwards.
  # The inbox must answer 202 without waiting on a third party's image server,
  # and nothing renders before the AI gate has seen the bytes anyway, so the
  # delivery only writes down what it wants.
  #
  # `sensitive` is the author's own call and covers every picture under the
  # post: their explicit flag, or a content warning, which is the same request
  # in different words.
  defp attach_pictures(%RemotePost{} = post, object) do
    post
    |> Media.record_attachments(List.wrap(object["attachment"]), RemotePost.warned?(post))
    |> Media.fetch_async()
  end

  @doc """
  Applies an author's edit of a post we cached (`Update`).

  Scoped to the account that wrote it, so one server cannot rewrite another's
  words, and it re-reads the audience: an author who narrows a public post to
  their followers has said "show this to fewer people", and that has to take
  effect. A narrowing past what we may keep at all deletes the row.
  """
  def update_remote_post(activity, actor_uri) when is_binary(actor_uri) do
    with %{} = object <- remote_post_object(activity["object"]),
         uri when is_binary(uri) <- object["id"],
         %RemotePost{} = post <- remote_post_by(uri, actor_uri) do
      apply_remote_post_update(post, object, activity)
    end

    :ok
  end

  def update_remote_post(_activity, _actor_uri), do: :ok

  @doc """
  Honours an upstream `Delete` of a cached post.

  Deliberately **un**gated, like `delete_reply/2`: an author withdrawing their
  words is the deletion path that makes storing them defensible in the first
  place, so it must not depend on any switch still being on. Scoped to the
  account that wrote it, so one server cannot delete another's.
  """
  def delete_remote_post(actor_uri, object_uri)
      when is_binary(actor_uri) and is_binary(object_uri) do
    if post = remote_post_by(object_uri, actor_uri) do
      # The author took their words back, so their pictures go with them.
      delete_cached_post(post)
    end

    :ok
  end

  def delete_remote_post(_actor_uri, _object_uri), do: :ok

  @doc """
  One page of the cached posts for `viewer`'s feed — the fourth source beside
  followed members, reposts and followed tags.

  Muted follows are left out (the subscription stays, the posts leave the feed,
  exactly as a muted local follow behaves), and a followers-only post reaches
  only a member whose own follow is **accepted**: a request nobody answered is
  not a relationship, so it does not open the author's restricted posts.

  `at` is the author's own `published_at` as a naive UTC stamp, because that is
  what the merged feed sorts on.
  """
  def feed_remote_posts(%User{id: viewer_id}, fetch_n, cursor) do
    if enabled?() do
      from(p in RemotePost,
        join: a in RemoteAccount,
        on: a.id == p.remote_account_id,
        join: f in Follow,
        on: f.remote_account_id == a.id,
        where: f.user_id == ^viewer_id and f.muted == false,
        where: p.audience in ^RemotePost.open_audiences() or f.state == "accepted",
        order_by: [desc: p.published_at, desc: p.id],
        limit: ^fetch_n,
        preload: [remote_account: a]
      )
      |> remote_posts_at_or_before(cursor)
      |> Repo.all()
      |> Enum.map(&remote_feed_entry/1)
    else
      []
    end
  end

  defp remote_feed_entry(%RemotePost{} = post) do
    %{
      id: "remote-#{post.id}",
      post: nil,
      remote_post: post,
      reposted_by: nil,
      at: DateTime.to_naive(post.published_at)
    }
  end

  defp remote_posts_at_or_before(query, nil), do: query

  defp remote_posts_at_or_before(query, %{at: at}) do
    where(query, [p], p.published_at <= ^DateTime.from_naive!(at, "Etc/UTC"))
  end

  @doc "One stored remote picture with its post, or nil."
  def get_remote_image(id) do
    UUIDv7.with_cast(id, &Repo.get(RemoteImage, &1)) |> Repo.preload(:remote_post)
  end

  @doc """
  Whether `viewer` may see a cached picture: exactly whether they may see the
  post it hangs off.

  A picture URL is the one thing a reader can hand to somebody else, so the
  proxy re-asks this per request rather than trusting that a card rendered it.
  """
  def remote_image_visible?(%RemoteImage{remote_post: %RemotePost{} = post}, viewer),
    do: remote_post_visible?(post, viewer)

  def remote_image_visible?(_image, _viewer), do: false

  @doc """
  Whether `viewer` may see a cached post: they follow its author (not muted —
  a mute is about the feed, not about access), and for a followers-only post
  that follow is accepted.

  The read half of what `feed_remote_posts/3` and `account_posts/2` enforce in
  SQL, for the one caller that has a post in hand rather than a query.
  """
  def remote_post_visible?(%RemotePost{} = post, %User{id: viewer_id}) do
    Repo.exists?(
      from(f in Follow,
        where: f.user_id == ^viewer_id and f.remote_account_id == ^post.remote_account_id,
        # The feed's vocabulary (`RemotePost.open?/1`), not a negated literal,
        # for the reason `account_posts/2` spells out: a fourth audience value
        # must not open here and close there.
        where: ^RemotePost.open?(post) or f.state == "accepted"
      )
    )
  end

  def remote_post_visible?(_post, _viewer), do: false

  @doc """
  Every picture recorded for `post_ids`, grouped by post id, in the author's
  order — including the ones still downloading or still with the AI gate.

  Deliberately *not* filtered to released pictures. The one thing that decides
  whether bytes reach a reader is `RemoteImage.released?/1`, at the point of
  rendering and again in the proxy, so a row here is not a permission. What the
  unreleased rows buy is the card being able to say "a picture is on its way"
  instead of rendering nothing: a post from another network can be a photograph
  and nothing else, and such a post with its picture silently missing is not a
  quiet card, it is a broken one.
  """
  def list_remote_images(post_ids) do
    from(i in RemoteImage,
      where: i.remote_post_id in ^post_ids,
      order_by: [asc: i.position, asc: i.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.remote_post_id)
  end

  @doc "One cached remote post with its account, or nil."
  def get_remote_post(id) do
    UUIDv7.with_cast(id, &Repo.get(RemotePost, &1)) |> Repo.preload(:remote_account)
  end

  @doc """
  Somebody reports a cached post as not appropriate. **Deletes it immediately**
  and records the takedown in the content-free ledger
  (`Vutuv.Fediverse.NoteEvent`), the same way a reported reply is handled and
  for the same reason: this is a cache of something that still exists at its
  origin, so removing it costs the author nothing they did not keep.

  Unlike a reported reply this sends **no `Flag`**. A reply arrived under a
  member's own post, addressed into a conversation here, and the thread's owner
  is a party that server already knows; a post from an account somebody chose to
  follow is simply that author publishing to their own followers, and filing a
  report about it in a member's name would put them in a message to strangers
  they never asked to send. Deleting our copy is the whole action.

  Rate limited per reporter (`remote_post_report_limit/0` a day).
  """
  def report_remote_post(post_id, %User{} = reporter) do
    case RateLimiter.hit(
           {:fediverse_post_report, reporter.id},
           @remote_post_report_limit,
           :timer.hours(24)
         ) do
      :ok -> take_down_remote_post(post_id, reporter)
      _ -> {:error, :rate_limited}
    end
  end

  defp take_down_remote_post(post_id, %User{} = reporter) do
    case get_remote_post(post_id) do
      %RemotePost{remote_account: %RemoteAccount{} = account} = post ->
        delete_cached_post(post)

        # No `user_id`: unlike a reply, a cached post sits under nobody's post,
        # so there is no member whose page it was on.
        log_takedown(%{
          action: "reported_post",
          host: account.host,
          actor_uri: account.actor_uri,
          audience: post.audience,
          actor_id: reporter.id
        })

        :ok

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Deletes the stored files of the pictures on `post_ids`, before their rows go.

  The rows cascade with their post, but files do not: a deletion that leaves
  bytes at rest is not a deletion, so every path that removes cached posts goes
  through here first — the bulk sweeps (expiry, the unfollow purge, an instance
  block, a deleted account) call it via `wipe_media/1`, and every single-post
  delete goes through `delete_cached_post/1`, which is the one place a post row
  is removed.
  """
  def delete_media_for_posts(post_ids) when is_list(post_ids) do
    from(i in RemoteImage, where: i.remote_post_id in ^post_ids, select: i.id)
    |> Repo.all()
    |> Enum.each(&RemoteMedia.delete_post_image/1)
  end

  # Deleting one cached post, pictures first. The wipe belongs *inside* the
  # delete rather than beside each caller: it was beside them, and three paths
  # (a member's report, an author narrowing their own post, the account's own
  # `Delete`) quietly did not have it, so a reader who reported a picture was
  # told "our copy was deleted right away" while the bytes stayed on disk.
  defp delete_cached_post(%RemotePost{} = post) do
    delete_media_for_posts([post.id])
    Repo.delete(post)
  end

  # The same, for a query that is about to delete posts: the ids are read out
  # first, because after the delete there is nothing left to read them from.
  # They are returned, so a caller that also wants to count what it removed
  # (`block_instance/2`) does not repeat the read.
  defp wipe_media(query) do
    ids = Repo.all(from(p in query, select: p.id))
    delete_media_for_posts(ids)
    ids
  end

  # The avatar twin, for a query that is about to delete accounts: their rows
  # cascade, their pictures on disk do not.
  defp wipe_avatars(query) do
    from(a in query, select: a.id)
    |> Repo.all()
    |> Enum.each(&RemoteMedia.delete_avatar/1)
  end

  @doc """
  Deletes every cached post past its ceiling — the floor under everything else,
  so a copy nobody looked at and no server told us about still goes.
  """
  def expire_due_remote_posts(now \\ nil), do: expire_due(RemotePost, now)

  @doc """
  Deletes the cached posts of every remote account nobody here follows any more.

  The account row itself stays: it may still be named by a reaction chip or a
  stored reply, and re-resolving it on the next follow would be a needless
  round trip. What goes is the content, which we only ever had a claim to hold
  because somebody here was following its author.

  This unscoped form is the **hourly sweep's**: it has to read every cached post
  to answer the question, which is what catches the follows that vanished
  through a cascade — a deleted account, a purged instance — without anybody
  calling it. The unfollow paths call `purge_unfollowed_remote_posts/1` instead,
  which asks the same question about the handful of accounts that just changed.
  """
  def purge_unfollowed_remote_posts do
    followed = from(f in Follow, select: f.remote_account_id, distinct: true)

    delete_unfollowed_posts(
      from(p in RemotePost, where: p.remote_account_id not in subquery(followed))
    )
  end

  @doc """
  The same purge, narrowed to the accounts somebody just stopped following.

  What the unfollow paths call, so the copy disappears the moment the reason for
  it does. Narrowed because the unscoped form above is a whole-table anti-join,
  and an unfollow is a member's own click inside their own request: it must not
  cost a scan of every cached post on the installation to drop the posts of one
  account.
  """
  def purge_unfollowed_remote_posts(account_ids) when is_list(account_ids) do
    still_followed =
      from(f in Follow, where: f.remote_account_id in ^account_ids, select: f.remote_account_id)

    delete_unfollowed_posts(
      from(p in RemotePost,
        where: p.remote_account_id in ^account_ids,
        where: p.remote_account_id not in subquery(still_followed)
      )
    )
  end

  defp delete_unfollowed_posts(query) do
    # Files first: the rows cascade, bytes on disk do not, and a deletion that
    # leaves a stranger's photograph at rest is not a deletion (issue #1163).
    wipe_media(query)
    {count, _} = Repo.delete_all(query)
    count
  end

  @doc "How many cached posts are stored across the installation."
  def remote_post_total, do: Repo.aggregate(RemotePost, :count)

  # How many of an account's cached posts the account page shows. It is a
  # preview — "what do they actually post", the thing that decides a follow —
  # not an archive of somebody else's writing, and the page says so when there
  # is more.
  @account_page_posts 30

  @doc """
  The cached posts of one account for `viewer`, newest first, as
  `{posts, more?}` (issue #1162).

  Audience-scoped exactly like the feed: public and unlisted for anybody signed
  in, followers-only solely for a viewer whose own follow is **accepted**. So the
  page can be opened by any member without becoming a way to read what an author
  addressed to their followers.

  The cap and the "there is more" flag are both answered here — one row past the
  cap is fetched and dropped — so no caller has to know the number or repeat the
  +1 trick to rediscover a fact this query already had.
  """
  def account_posts(%RemoteAccount{id: account_id}, %User{id: viewer_id}) do
    accepted =
      from(f in Follow,
        where:
          f.remote_account_id == ^account_id and f.user_id == ^viewer_id and
            f.state == "accepted"
      )

    from(p in RemotePost,
      where: p.remote_account_id == ^account_id,
      # The feed's vocabulary, not a negated literal: `open_audiences/0` is the
      # one list the query and the card (`RemotePost.open?/1`) both read, so a
      # fourth audience value cannot open here and close there.
      where: p.audience in ^RemotePost.open_audiences() or exists(accepted),
      order_by: [desc: p.published_at, desc: p.id],
      limit: ^(@account_page_posts + 1)
    )
    |> Repo.all()
    |> Enum.split(@account_page_posts)
    |> then(fn {posts, rest} -> {posts, rest != []} end)
  end

  @doc """
  Drops every stored remote account nothing refers to any more (issue #1162).

  An account row is minted for three reasons — somebody followed it, it replied
  under a member's post, or it reacted to one — and it is kept only while one of
  those still holds. The follows and the cached posts are foreign keys; the
  replies and reactions name the actor by URI, so those are matched on the URI.

  This is what keeps "we remember who reacted to your post" from quietly
  becoming "we keep a directory of everybody who ever touched this
  installation".
  """
  def purge_unreferenced_remote_accounts do
    unreferenced = unreferenced_accounts_query()

    # Their avatar files, before the rows go: the row cascade cannot reach
    # bytes on disk (issue #1163).
    wipe_avatars(unreferenced)

    {count, _} = Repo.delete_all(unreferenced)
    count
  end

  defp unreferenced_accounts_query do
    from(a in RemoteAccount,
      as: :account,
      # All four written the same way, as `NOT EXISTS`: an `a.id not in
      # subquery(...)` form makes the planner hash every row of the other
      # table first (a whole scan of the installation-wide post cache on
      # every sweep), while a correlated anti-join can use that table's own
      # index per candidate row.
      where: not exists(from(f in Follow, where: f.remote_account_id == parent_as(:account).id)),
      where:
        not exists(from(p in RemotePost, where: p.remote_account_id == parent_as(:account).id)),
      where: not exists(from(n in Note, where: n.actor_uri == parent_as(:account).actor_uri)),
      where: not exists(from(r in Reaction, where: r.actor_uri == parent_as(:account).actor_uri))
    )
  end

  @doc """
  What each remote server has stored here as cached posts, biggest first — the
  third column of the operator's `/admin/fediverse` picture, beside the follower
  and reply volumes. Capped at `limit` hosts.
  """
  def remote_post_hosts(limit \\ 20) do
    Repo.all(
      from(p in RemotePost,
        join: a in RemoteAccount,
        on: a.id == p.remote_account_id,
        group_by: a.host,
        order_by: [desc: count(p.id)],
        limit: ^limit,
        select: %{host: a.host, posts: count(p.id)}
      )
    )
  end

  # The account behind an actor URI, but only when somebody here has an
  # **accepted** follow of it. A requested-but-unanswered follow does not open
  # the door: the other server has not agreed to anything, and neither have we.
  defp followed_account(actor_uri) do
    Repo.one(
      from(a in RemoteAccount,
        join: f in Follow,
        on: f.remote_account_id == a.id,
        where: a.actor_uri == ^actor_uri and f.state == "accepted",
        limit: 1
      )
    )
  end

  # An activity delivers what it claims, or it is dropped. A `Question` is a
  # poll; every other object type keeps the 202-and-drop.
  defp remote_post_object(%{"type" => type} = object) when type in ~w(Note Question), do: object
  defp remote_post_object(_object), do: nil

  # How the post was addressed, read from `to`/`cc` on both the Create and the
  # object (servers put the audience on either).
  #
  #   public   — the public collection in `to`: on that server's timelines.
  #   unlisted — the public collection in `cc` only: deliverable to followers,
  #              kept out of that server's discovery surfaces.
  #   followers — a followers collection and nothing public.
  #
  # Anything else (a direct message, an audience we cannot read) is **not
  # stored at all**. A reply had to be kept in order to reach the member it was
  # addressed to; a post nobody here was published to has no such claim.
  defp remote_post_audience(object, activity) do
    to = normalize_uri_list(object["to"]) ++ normalize_uri_list(activity["to"])
    cc = normalize_uri_list(object["cc"]) ++ normalize_uri_list(activity["cc"])

    cond do
      Enum.any?(to, &(&1 in @public_collections)) -> "public"
      Enum.any?(cc, &(&1 in @public_collections)) -> "unlisted"
      Enum.any?(to ++ cc, &String.ends_with?(&1, @followers_suffix)) -> "followers"
      true -> nil
    end
  end

  # Whether this is the author's own thread rather than a reply into somebody
  # else's conversation. A top-level post always is; a reply is kept only when
  # it continues a post of theirs we already hold.
  #
  # The line is deliberate: a followed account's own thread is what a follower
  # subscribed to, while their reply under a stranger's post drags a third
  # party's conversation into our storage for the sake of one half of it.
  defp own_thread?(%{"inReplyTo" => parent}, %RemoteAccount{} = account) when is_binary(parent) do
    Repo.exists?(
      from(p in RemotePost,
        where: p.object_uri == ^parent and p.remote_account_id == ^account.id
      )
    )
  end

  defp own_thread?(_object, _account), do: true

  defp insert_remote_post(%RemoteAccount{} = account, object, audience) do
    received = DateTime.utc_now(:second)

    with uri when is_binary(uri) <- presence(object["id"]),
         # Text, or a picture, or both. A picture-only post used to be dropped
         # for having nothing to show; since issue #1163 the picture IS what it
         # has, so an empty body only disqualifies a post that carries no
         # picture either — a row about a third party still has to earn its
         # place, but a photograph earns it.
         text when is_binary(text) <-
           remote_post_text(object) || picture_only_text(object) do
      %RemotePost{remote_account_id: account.id}
      |> RemotePost.changeset(
        Map.merge(remote_post_attrs(object, text, audience), %{
          object_uri: uri,
          in_reply_to_uri: object["inReplyTo"],
          origin_url: presence(object["url"]),
          kind: remote_post_kind(object),
          published_at: published_at(object["published"], received),
          received_at: received,
          expires_at: DateTime.add(received, remote_post_retention_days() * 86_400)
        })
      )
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:object_uri])
      |> stored_post(uri)
    else
      _ -> :error
    end
  end

  # Which row this delivery actually left behind, and whether it was *this*
  # delivery that wrote it.
  #
  # `on_conflict: :nothing` cannot say: the v7 id is minted in Elixir, so the
  # struct comes back looking identical whether the row landed or collided —
  # and on a collision that id names no row at all. Writing the post's pictures
  # against it therefore raised a foreign-key error and 500ed the inbox, on the
  # most ordinary delivery pattern there is: two members following the same
  # account each get their own copy of the same `Create`, and a sender that
  # gets a 500 retries the whole batch forever.
  #
  # Reading the row back by its one unique column answers both questions at
  # once — the struct that really exists, and (by the id) whose insert it was.
  # A redelivery is `:exists`, which the caller drops, so a post's pictures are
  # recorded exactly once.
  defp stored_post({:ok, %RemotePost{id: minted_id}}, uri) do
    case Repo.get_by(RemotePost, object_uri: uri) do
      %RemotePost{id: ^minted_id} = post -> {:ok, post}
      %RemotePost{} -> :exists
      nil -> :error
    end
  end

  defp stored_post(_result, _uri), do: :error

  # Everything about a cached post its author can still change after publishing.
  # Shared by the insert and the `Update` path, so an edit cannot silently stop
  # carrying a field the insert writes.
  defp remote_post_attrs(object, text, audience) do
    %{
      content_text: text,
      summary: remote_text(object["summary"], RemotePost.max_summary()),
      sensitive: object["sensitive"] == true,
      audience: audience
    }
  end

  defp remote_post_kind(%{"type" => "Question"}), do: "question"
  defp remote_post_kind(_object), do: "note"

  # The post's text, with a poll's options folded in as lines. Carrying a vote is
  # not something we can do, so the card links back to the original to vote —
  # but a poll whose options are invisible is not a poll, it is a question with
  # no answers.
  defp remote_post_text(%{"type" => "Question"} = object) do
    options =
      object
      |> poll_options()
      |> Enum.map_join("\n", &("• " <> &1))

    [remote_text(object["content"], RemotePost.max_content()), presence(options)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> presence()
  end

  defp remote_post_text(object), do: remote_text(object["content"], RemotePost.max_content())

  # The body of a post whose author wrote no words: the empty string, when it
  # carries at least one picture (and nil otherwise, which drops the post).
  #
  # Empty on purpose, and emphatically NOT a rendered sentence like "(a
  # picture)". The inbox runs no `:browser` pipeline, so it has no locale: a
  # translated string built here freezes the **English** one into the column
  # for every German reader on this German site, permanently — and it would
  # then be what the agent formats quote, what the search text indexes and what
  # the muted-word filter matches (muting "picture" would hide every wordless
  # photo post). The reader is told there is a picture by seeing it, in the
  # card, in their own language.
  defp picture_only_text(object) do
    pictures = object["attachment"] |> List.wrap() |> Enum.filter(&Media.image_attachment?/1)
    if pictures != [], do: ""
  end

  # A poll's options live under `oneOf` (pick one) or `anyOf` (pick several),
  # each a Note whose `name` is the option text.
  defp poll_options(object) do
    options =
      for option <- List.wrap(object["oneOf"]) ++ List.wrap(object["anyOf"]),
          is_map(option),
          name = presence(option["name"]),
          do: name

    Enum.take(options, 20)
  end

  # The author's own stamp, which is what orders the feed — clamped against the
  # future, so a server cannot pin itself to the top of somebody's feed forever
  # by publishing with a date in 2099. An unreadable or absent stamp falls back
  # to arrival.
  defp published_at(value, received) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> Enum.min([DateTime.truncate(at, :second), received], DateTime)
      _ -> received
    end
  end

  defp published_at(_value, received), do: received

  defp remote_post_by(object_uri, actor_uri) do
    Repo.one(
      from(p in RemotePost,
        join: a in RemoteAccount,
        on: a.id == p.remote_account_id,
        where: p.object_uri == ^object_uri and a.actor_uri == ^actor_uri
      )
    )
  end

  defp apply_remote_post_update(%RemotePost{} = post, object, activity) do
    # The same "text, or a picture, or both" the insert accepts. Reading only
    # the text here deleted a photo post the moment its author edited it — and
    # they edit for an added content warning, a fixed alt text or a poll tick,
    # not just for words.
    text = remote_post_text(object) || picture_only_text(object)
    audience = remote_post_audience(object, activity)

    if is_nil(text) or is_nil(audience) do
      # The author narrowed it past what we may hold, or emptied it: the same
      # "stop showing this" signal a `Delete` carries, just spelled differently.
      delete_cached_post(post)
    else
      with {:ok, updated} <-
             post
             |> RemotePost.changeset(remote_post_attrs(object, text, audience))
             |> Repo.update() do
        # An edit is where a picture is added, dropped, described or covered —
        # see `Media.sync_attachments/3`.
        updated
        |> Media.sync_attachments(List.wrap(object["attachment"]), RemotePost.warned?(updated))
        |> Media.fetch_async()
      end
    end
  end

  ## Pruning followers whose account is gone (issue #1072)

  # Not every departure is announced. An `Undo(Follow)` or the remote actor's
  # own `Delete` removes a follower at once, but a server that simply stops
  # answering for one account tells us nothing — deliveries go to its shared
  # inbox, which keeps working for everybody else on that server. So each
  # follower row is re-fetched on a slow rotation and dropped only on the two
  # answers that mean the account itself is gone.
  #
  # Slow and bounded on purpose: one row is re-checked at most every
  # @prune_recheck_days, a run takes at most @prune_batch rows and at most
  # @prune_per_host of them from any one server, and the run is hourly
  # (`Vutuv.Fediverse.FollowerPruner`). A big server therefore sees a handful
  # of plain GETs an hour, never a sweep of its whole roster.
  @prune_recheck_days 30
  @prune_batch 50
  @prune_per_host 10

  # 404 (no such actor) and 410 (Gone — what the common server implementations
  # answer for a deleted account) are the only answers that prune. A timeout, a
  # connection error, a 5xx, a 429 rate limit or a redirect all mean the server
  # is having a bad day, not that a person left, so the row stays.
  @gone_statuses [404, 410]

  @doc "How long (days) before one follower row is re-checked again."
  def prune_recheck_days, do: @prune_recheck_days

  @doc "How many follower rows one pruning run checks at most."
  def prune_batch, do: @prune_batch

  @doc """
  Re-checks the follower rows that are due and drops the ones whose remote
  account is gone, recording each removal in the prune ledger
  (`Vutuv.Fediverse.FollowerPrune`) for the nightly Tagesbericht. Returns how
  many rows were pruned. A no-op — and no outbound request at all — when the
  installation-wide switch is off.

  Called by `Vutuv.Fediverse.FollowerPruner`; tests call it directly.
  """
  def prune_due_followers(now \\ NaiveDateTime.utc_now()) do
    now = NaiveDateTime.truncate(now, :second)

    if enabled?(), do: do_prune_due_followers(now), else: 0
  end

  defp do_prune_due_followers(now) do
    due = followers_due_for_prune(now)
    actors = actors_by_user_id(due)

    # Each check is one blocking HTTPS round trip (no DB connection held during
    # it), so run a few at a time instead of summing every remote's latency.
    due
    |> Task.async_stream(&check_follower(&1, actors[&1.user_id], now),
      max_concurrency: 5,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.count(&(&1 == {:ok, :pruned}))
  end

  @doc """
  The follower rows due for a re-check: never checked, or last checked longer
  than `prune_recheck_days/0` ago. Oldest first, capped at `prune_batch/0` rows
  and at `@prune_per_host` rows per remote server.
  """
  def followers_due_for_prune(now \\ NaiveDateTime.utc_now()) do
    cutoff =
      NaiveDateTime.add(NaiveDateTime.truncate(now, :second), -@prune_recheck_days * 86_400)

    from(f in Follower,
      where: is_nil(f.last_checked_at) or f.last_checked_at < ^cutoff,
      order_by: [asc_nulls_first: f.last_checked_at, asc: f.id],
      # Read a wider window than one batch: a server with thousands of stale
      # rows would otherwise fill the batch by itself and the per-host cap
      # would leave the run half empty, starving everybody else.
      limit: ^(@prune_batch * 4),
      preload: [:user]
    )
    |> Repo.all()
    |> spread_across_hosts()
  end

  defp spread_across_hosts(followers) do
    followers
    |> Enum.reduce({[], %{}}, fn follower, {kept, per_host} ->
      host = BlockedInstance.normalize_host(follower.actor_uri) || follower.actor_uri
      taken = Map.get(per_host, host, 0)

      if taken < @prune_per_host,
        do: {[follower | kept], Map.put(per_host, host, taken + 1)},
        else: {kept, per_host}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.take(@prune_batch)
  end

  defp check_follower(%Follower{} = follower, actor, now) do
    case fetch_remote_actor(follower.actor_uri, signer_for(follower.user, actor)) do
      {:error, {:http, status}} when status in @gone_statuses ->
        prune_follower(follower, status)

      _ ->
        touch_follower(follower, now)
    end
  end

  defp prune_follower(%Follower{} = follower, status) do
    Repo.delete(follower)

    # The host is always parseable here (an unparseable actor URI never gets as
    # far as an HTTP status), but fall back rather than lose the ledger row: a
    # deletion the report cannot see is exactly what this is meant to prevent.
    %FollowerPrune{user_id: follower.user_id}
    |> FollowerPrune.changeset(%{
      host: BlockedInstance.normalize_host(follower.actor_uri) || "unknown",
      status: status
    })
    |> Repo.insert()

    :pruned
  end

  # Everything that is not a "gone" answer only moves the clock, so the next run
  # picks up other rows instead of hammering the same unhappy server.
  defp touch_follower(%Follower{} = follower, now) do
    follower |> Ecto.Changeset.change(last_checked_at: now) |> Repo.update()
    :kept
  end

  defp signer_for(%User{} = user, %Actor{} = actor),
    do: {Docs.key_id(user), actor.private_key_pem}

  defp signer_for(_user, _actor), do: nil

  ## Blocked instances and inbound caps (issue #1067)

  # The operator's safety floor under everything inbound. Two independent
  # levers, because they answer different abuse: the **blocklist** shuts one
  # named server out for good, the **caps** bound how much any single server (or
  # single remote person) can push in an hour, including servers nobody has
  # thought to block yet.
  #
  # Stored inbound rows per hour, per remote host and per remote actor. Generous
  # on purpose: a big instance legitimately sends a burst when a post travels,
  # and a cap that bites honest traffic gets turned off. Overridable via
  # `config :vutuv, :fediverse_inbound_caps, {host_limit, actor_limit}`.
  @inbound_host_limit 600
  @inbound_actor_limit 60

  # Answers a member may send out to other networks per hour (issue #1070). Set
  # for a person holding a conversation, not for a script: a real exchange is a
  # handful of messages, so this only ever bites automation.
  @outbound_reply_limit 30

  # Likes a member may send out per hour (issue #1164). Its own budget, and a
  # much larger one than the replies above: a like is one tap while reading, so
  # a limit sized for writing prose would refuse ordinary reading. It is still
  # a limit, because this is a member action that makes vutuv POST to a server
  # that never followed them.
  @outbound_like_limit 200

  # How long a post with an unvetted picture is held before it federates without
  # it. The ceiling, not the normal wait — see `image_hold_seconds/0`.
  @image_hold_seconds 90

  @doc "Every blocked remote server, newest first, with who blocked it."
  def list_blocked_instances do
    Repo.all(from(b in BlockedInstance, order_by: [desc: b.id], preload: [:blocked_by]))
  end

  @doc "How many remote servers the operator has shut out."
  def blocked_instance_count, do: Repo.aggregate(BlockedInstance, :count)

  @doc """
  Whether anything from `uri` (an actor id, a `keyId`, a bare host) must be
  dropped. Called by the inbox **before** the signature is verified and before
  the remote actor is fetched, so a blocked server costs us neither an outbound
  request nor a write. A `nil`/unparseable host is not blocked — the request
  fails the signature check moments later anyway.
  """
  def instance_blocked?(uri) do
    case BlockedInstance.normalize_host(uri) do
      nil -> false
      host -> Repo.exists?(from(b in BlockedInstance, where: b.host == ^host))
    end
  end

  @doc """
  Blocks a remote server and purges everything already stored from it.

  Blocking is not just "stop listening": the follower rows from that host are
  also the delivery targets for the member's future posts, so leaving them would
  keep federating *to* a server we refuse to hear from. So the block and the
  purge are one action — see `purge_instance/1` for what goes.

  Returns `{:ok, {blocked, purged}}` where `purged` is the per-table row count,
  or `{:error, changeset}`.
  """
  def block_instance(attrs, %User{} = admin) do
    changeset =
      %BlockedInstance{blocked_by_id: admin.id}
      |> BlockedInstance.changeset(attrs)

    case Repo.insert(changeset) do
      {:ok, blocked} -> {:ok, {blocked, purge_instance(blocked.host)}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Lifts a block. Deliberately does **not** resurrect anything: the purged rows
  are gone, and a remote that wants to follow again simply sends a new Follow.
  """
  def unblock_instance(id) do
    case Repo.get(BlockedInstance, id) do
      nil -> {:error, :not_found}
      blocked -> Repo.delete(blocked)
    end
  end

  @doc """
  Deletes everything stored from `host`: its remote followers, the accounts its
  members hold that anybody here follows (and, through the cascade, those
  follows), the replies its members wrote under vutuv posts, the outbound
  deliveries still queued for it and the records of what was delivered there.
  Returns `%{followers: n, remote_accounts: n, notes: n, deliveries: n,
  post_deliveries: n}`.
  """
  def purge_instance(host) when is_binary(host) do
    {followers, _} =
      Repo.delete_all(from(f in Follower, where: uri_host(f.actor_uri) == ^host))

    # A block cuts both directions (issue #1160): the accounts our members
    # follow over there go with the ones that follow us, and the follow rows
    # cascade off them — as do their cached posts (issue #1161), which is why
    # they are counted before the delete rather than deleted separately.
    # Nothing is sent: a blocked server is not talked to, not even to say
    # goodbye.
    host_posts =
      from(p in RemotePost,
        join: a in RemoteAccount,
        on: a.id == p.remote_account_id,
        where: a.host == ^host
      )

    # Their pictures' files, and the avatars, before the rows cascade away
    # (issue #1163): a blocked server must leave nothing of itself at rest.
    # The wipe hands back the post ids it read, which is also the tally.
    cached_posts = length(wipe_media(host_posts))

    wipe_avatars(from(a in RemoteAccount, where: a.host == ^host))

    {remote_accounts, _} =
      Repo.delete_all(from(a in RemoteAccount, where: a.host == ^host))

    # A block is also a takedown: text that server's members wrote under our
    # members' posts goes with it (issue #1069), not just the follow rows.
    {notes, _} =
      Repo.delete_all(from(n in Note, where: uri_host(n.actor_uri) == ^host))

    {deliveries, _} =
      Repo.delete_all(from(d in Delivery, where: uri_host(d.inbox_uri) == ^host))

    # A blocked server is not talked to again, so the record of what it received
    # (issue #1102) would only ever address a revocation nobody will deliver.
    {post_deliveries, _} =
      Repo.delete_all(from(d in PostDelivery, where: uri_host(d.inbox_uri) == ^host))

    %{
      followers: followers,
      remote_accounts: remote_accounts,
      cached_posts: cached_posts,
      notes: notes,
      deliveries: deliveries,
      post_deliveries: post_deliveries
    }
  end

  @doc """
  What each remote server has stored here, all of it, biggest first — the
  operator's "who is sending us the most" table on `/admin/fediverse`, and what
  a block decision is made from.

  Merged across the three things a server can leave here: followers of our
  members, replies under their posts (issue #1069) and cached posts from
  accounts they follow (issue #1161). Merged rather than joined onto the
  follower list, because a server can appear through any one of them alone — a
  member following an account somewhere nobody there follows back is exactly the
  case the follower-keyed table used to miss, and it is the case that arrives
  with somebody else's content.

  Rows are `%{host:, followers:, notes:, posts:}`, sorted by the total, capped
  at `limit`.
  """
  def inbound_volume(limit \\ 20) do
    # Every source already returns `%{host: …, <its own key>: count}`, so merging
    # them is a group-by on the host with the missing keys defaulted. A fourth
    # inbound kind joins the list and the blank row, and nothing else changes.
    blank = %{followers: 0, notes: 0, posts: 0}

    [inbound_hosts(limit), note_hosts(limit), remote_post_hosts(limit)]
    |> Enum.concat()
    |> Enum.group_by(& &1.host)
    |> Enum.map(fn {host, rows} ->
      Enum.reduce(rows, Map.put(blank, :host, host), &Map.merge(&2, &1))
    end)
    |> Enum.sort_by(&(&1.followers + &1.notes + &1.posts), :desc)
    |> Enum.take(limit)
  end

  @doc """
  How many remote followers each server has here, biggest first — one of the
  three columns `inbound_volume/1` merges. Capped at `limit` hosts.
  """
  def inbound_hosts(limit \\ 20) do
    Repo.all(
      from(f in Follower,
        group_by: uri_host(f.actor_uri),
        order_by: [desc: count(f.id)],
        limit: ^limit,
        select: %{host: uri_host(f.actor_uri), followers: count(f.id)}
      )
    )
  end

  @doc """
  The inbound caps as `{host_limit, actor_limit}` per hour, for the admin
  screen to state what it is enforcing.
  """
  def inbound_caps do
    Application.get_env(:vutuv, :fediverse_inbound_caps, {
      @inbound_host_limit,
      @inbound_actor_limit
    })
  end

  # One hourly budget per remote host and one per remote actor, checked right
  # before a row is stored. The host bucket is hit FIRST and short-circuits, so
  # a flooding server cannot also plant one actor bucket per forged actor id
  # after its own budget is spent (the same rule `VutuvWeb.RateLimit` follows).
  defp check_inbound_cap(actor_uri) when is_binary(actor_uri) do
    {host_limit, actor_limit} = inbound_caps()
    host = BlockedInstance.normalize_host(actor_uri) || actor_uri

    with :ok <- RateLimiter.hit({:fediverse_inbound, :host, host}, host_limit, @inbound_window_ms),
         :ok <-
           RateLimiter.hit(
             {:fediverse_inbound, :actor, actor_uri},
             actor_limit,
             @inbound_window_ms
           ) do
      :ok
    else
      _ -> {:error, :inbound_capped}
    end
  end

  defp check_inbound_cap(_), do: :ok

  ## The shared inbox (issue #1073)

  # How many addressee URIs one delivery may name. `to`/`cc` are attacker-chosen
  # text and each entry costs a lookup, so the list is cut rather than walked:
  # a real mention list is a handful of accounts, far under this. The fan-out
  # that is NOT capped is the actor-lifecycle one below, because it is bounded
  # by rows we ourselves wrote (who really follows whom), and it is exactly the
  # work the per-member inbox would otherwise do across N separate requests.
  @inbox_addressed_cap 25

  @doc """
  Every local member a delivery to the **shared inbox** is for (issue #1073).

  The per-member inbox learns who the activity is for from the URL; the shared
  one has to read it out of the activity. Three sources, because that is where
  ActivityPub actually puts it:

    * the **addressing** — `to` / `cc` / `bto` / `bcc` / `audience` on the
      activity and on its object — plus the object itself and, for an `Undo`,
      the object it wraps: a `Follow` names an actor URL, a `Like` or
      `Announce` a Note URL, a reply its `inReplyTo`. Every URL of ours resolves
      to the member it hangs off.
    * the **remote actor's own lifecycle** (`Update`/`Delete` of itself), which
      names no local member at all: it is broadcast to everyone with a stake in
      that actor, so the addressees are the members it follows here **and**
      (issue #1160) the members who follow it. This is the case the endpoint is
      worth having for — one account deletion used to mean one signed delivery
      per member.
    * an author's **`Update`/`Delete` of a note they wrote**, which likewise
      names nobody here: the addressees are the members whose posts hold a
      stored copy of it.

  Members who do not federate (or are suspended, frozen, gone) are filtered out,
  so a delivery to them is silently dropped — never answered differently, or the
  endpoint would become a way to ask who takes part.

  `actor_uri` is the activity's *claimed* actor. The caller resolves recipients
  before the signature is verified (it needs one of their keys to sign the
  actor fetch that verification depends on) and only acts on the result
  afterwards, once that claim is proven.
  """
  def inbox_recipients(activity, actor_uri) when is_map(activity) do
    (addressed_users(activity) ++ lifecycle_users(activity, actor_uri))
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(&federated?/1)
  end

  def inbox_recipients(_activity, _actor_uri), do: []

  defp addressed_users(activity) do
    object = if is_map(activity["object"]), do: activity["object"], else: %{}
    base = String.trim_trailing(VutuvWeb.Endpoint.url(), "/") <> "/"

    # `object["actor"]` is what names us in an `Accept`/`Reject` (issue #1160):
    # the answer wraps the Follow we sent, whose actor is our own member, and
    # nothing else in the document mentions them.
    (audience_uris(activity) ++
       audience_uris(object) ++
       [activity["object"], object["object"], object["actor"], object["inReplyTo"]])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(@inbox_addressed_cap)
    |> Enum.flat_map(&local_username(&1, base))
    |> users_by_username()
  end

  defp audience_uris(map) when is_map(map) do
    Enum.flat_map(~w(to cc bto bcc audience), fn field ->
      case map[field] do
        list when is_list(list) -> list
        uri when is_binary(uri) -> [uri]
        _ -> []
      end
    end)
  end

  defp audience_uris(_other), do: []

  # The member an actor or Note URL of ours hangs off, as a username. Anything
  # else — a foreign host, the public collection, a malformed URI — is a miss.
  defp local_username(uri, base) do
    case String.replace_prefix(uri, base, "") do
      ^uri -> []
      rest -> rest |> String.split("/") |> username_from_segments()
    end
  end

  defp username_from_segments([username, "actor" | _rest]), do: [String.downcase(username)]
  defp username_from_segments([username, "posts", _id | _rest]), do: [String.downcase(username)]
  defp username_from_segments(_segments), do: []

  # One query for the whole addressee list, not one per URI.
  defp users_by_username([]), do: []

  defp users_by_username(usernames),
    do: Repo.all(from(u in User, where: u.username in ^usernames))

  # A post an account publishes to its followers (issue #1161) names no local
  # member at all — the addressing is the public collection and the author's own
  # followers collection. The members it concerns are the ones who follow that
  # account here, and naming them matters for more than the fan-out: the shared
  # inbox signs its actor fetch with the first resolved addressee's key, and an
  # authorized-fetch server refuses an anonymous one, so a delivery that
  # resolved to nobody would fail verification and the post would be lost.
  defp lifecycle_users(%{"type" => "Create"}, actor_uri) when is_binary(actor_uri),
    do: remote_follow_users(actor_uri)

  defp lifecycle_users(%{"type" => type} = activity, actor_uri)
       when type in ~w(Update Delete) and is_binary(actor_uri) do
    case activity_object_id(activity["object"]) do
      ^actor_uri ->
        followed_local_users(actor_uri) ++ remote_follow_users(actor_uri)

      # An author editing or withdrawing something they wrote: the members whose
      # posts hold a copy of it, plus (issue #1161) the members who follow them,
      # since a cached post of theirs may be the thing being changed.
      uri when is_binary(uri) ->
        note_holding_users(actor_uri, uri) ++ remote_follow_users(actor_uri)

      _ ->
        []
    end
  end

  defp lifecycle_users(_activity, _actor_uri), do: []

  defp followed_local_users(actor_uri) do
    Repo.all(
      from(f in Follower,
        join: u in User,
        on: u.id == f.user_id,
        where: f.actor_uri == ^actor_uri,
        select: u
      )
    )
  end

  defp note_holding_users(actor_uri, object_uri) do
    Repo.all(
      from(n in Note,
        join: p in Post,
        on: p.id == n.post_id,
        join: u in User,
        on: u.id == p.user_id,
        where: n.object_uri == ^object_uri and n.actor_uri == ^actor_uri,
        distinct: true,
        select: u
      )
    )
  end

  ## Inbound reactions (issue #1068)

  @doc """
  Records what somebody on another network did with a member's post: a `Like`
  (they favourited it) or an `Announce` (they re-shared it). Idempotent per
  remote person per post per kind, so a repeat activity never double-counts.

  Every gate that must hold before a third party's row is stored, in order: the
  installation switch, the member federates and has not switched the counts off,
  the object really is one of *their* public posts (a Note URL we serve), the
  post is public, and the sending server is within its inbound cap. Anything
  else is `:skip` — the inbox acknowledges and drops it either way, so a
  misdirected activity never tells the sender what happened.

  `actor` is the remote actor as `%{uri:, handle:}` (the inbox has the fetched
  document in hand), or a bare URI string when there is no handle to keep.

  Broadcasts the post's counters afterwards, so an open action bar ticks over
  without a reload, and tells the author — a favourite or a boost from out
  there is news exactly like a vutuv like, and until it notified nothing the
  count simply crept up unseen.
  """
  def record_reaction(%User{} = user, object, kind, actor) when kind in ~w(like announce) do
    %{uri: actor_uri} = actor = actor_attrs(actor)

    with true <- enabled?(),
         true <- federated?(user),
         true <- user.fediverse_reactions?,
         %Post{} = post <- resolve_own_note(user, object),
         false <- Posts.restricted?(post),
         :ok <- check_inbound_cap(actor_uri),
         {:ok, reaction} <- insert_reaction(post, actor, kind) do
      Posts.broadcast_post_counters(post.id)
      notify_reaction(user, post, reaction)
      :ok
    else
      _ -> :skip
    end
  end

  # Both call shapes as one map. A bare URI is what an `Undo` and the tests
  # carry; the inbox passes the actor document's `preferredUsername` along.
  defp actor_attrs(uri) when is_binary(uri), do: %{uri: uri, handle: nil}
  defp actor_attrs(%{uri: uri} = actor), do: %{uri: uri, handle: actor[:handle]}
  defp actor_attrs(other), do: %{uri: other, handle: nil}

  # Only a genuinely new row is news: a redelivery of a Like we already hold
  # must not ring the bell a second time (`insert_reaction/3` reports it as
  # `:exists`).
  defp notify_reaction(user, post, %Reaction{} = reaction),
    do: Activity.notify_fediverse_reaction(user, post, reaction)

  defp notify_reaction(_user, _post, :exists), do: :ok

  @doc """
  Removes a reaction the remote side took back (`Undo(Like)` / `Undo(Announce)`).
  Honoured at once and unconditionally — an upstream withdrawal is the deletion
  path that makes storing the row defensible, so it must not depend on any
  switch still being on.
  """
  def remove_reaction(%User{} = user, object, kind, actor_uri) when kind in ~w(like announce) do
    with %Post{} = post <- resolve_own_note(user, object) do
      {count, _} =
        Repo.delete_all(
          from(r in Reaction,
            where: r.post_id == ^post.id and r.actor_uri == ^actor_uri and r.kind == ^kind
          )
        )

      if count > 0, do: Posts.broadcast_post_counters(post.id)
    end

    :ok
  end

  @doc "How many people on other networks reacted to this post."
  def reaction_count(post_id) do
    Repo.aggregate(from(r in Reaction, where: r.post_id == ^post_id), :count)
  end

  @doc """
  Drops every reaction stored for a member's posts — what switching the counts
  off means. Nothing is kept "just in case": the switch is the member's
  deletion lever over third-party data they never asked for.
  """
  def drop_reactions(%User{id: user_id}) do
    {count, _} =
      Repo.delete_all(
        from(r in Reaction,
          where:
            r.post_id in subquery(from(p in Post, where: p.user_id == ^user_id, select: p.id))
        )
      )

    count
  end

  # Validated by the changeset, written by `insert_all` — because the caller
  # has to know whether this delivery was *new*. `Repo.insert(on_conflict:
  # :nothing)` cannot say: the v7 id is minted in Elixir, so the struct it hands
  # back looks identical whether the row landed or collided. `insert_all`'s row
  # count is the honest answer, and `:exists` is what keeps a redelivery from
  # notifying twice.
  defp insert_reaction(post, actor, kind) do
    changeset =
      %Reaction{post_id: post.id}
      |> Reaction.changeset(%{
        actor_uri: actor.uri,
        # Cosmetic, remote-supplied and hostile: cut it to a column's worth
        # rather than lose the whole reaction to an over-long one.
        handle: truncate_handle(actor.handle),
        kind: kind,
        received_at: DateTime.utc_now(:second)
      })

    with {:ok, reaction} <- Ecto.Changeset.apply_action(changeset, :insert) do
      row = %{
        id: UUIDv7.generate(),
        post_id: post.id,
        actor_uri: reaction.actor_uri,
        handle: reaction.handle,
        kind: reaction.kind,
        received_at: reaction.received_at
      }

      case Repo.insert_all(Reaction, [row],
             on_conflict: :nothing,
             conflict_target: [:post_id, :actor_uri, :kind],
             returning: true
           ) do
        {0, _} -> {:ok, :exists}
        {1, [inserted]} -> {:ok, inserted}
      end
    end
  end

  defp truncate_handle(handle) when is_binary(handle), do: String.slice(handle, 0, 255)
  defp truncate_handle(_handle), do: nil

  # The post behind an activity's `object`, but only when it is a Note URL we
  # serve for *this* member. A URL naming somebody else's post, a foreign host,
  # or a malformed id is a miss (nil), never a raise.
  defp resolve_own_note(user, object) do
    prefix = Docs.note_url(user, "")

    with uri when is_binary(uri) <- activity_object_id(object),
         post_id when post_id != uri <- String.replace_prefix(uri, prefix, ""),
         %Post{user_id: user_id} = post when user_id == user.id <-
           UUIDv7.with_cast(post_id, &Repo.get(Post, &1)) do
      post
    else
      _ -> nil
    end
  end

  # An activity's object is either an embedded document or a bare id URI.
  defp activity_object_id(%{"id" => id}) when is_binary(id), do: id
  defp activity_object_id(id) when is_binary(id), do: id
  defp activity_object_id(_), do: nil

  ## Inbound replies (issues #1069 and #1071)

  @doc "How long a stored remote reply may live at the very most (days)."
  def note_retention_days,
    do: Application.get_env(:vutuv, :fediverse_note_retention_days, @note_retention_days)

  @doc "How stale a stored reply may get before its origin is asked again (days)."
  def note_refresh_days,
    do: Application.get_env(:vutuv, :fediverse_note_refresh_days, @note_refresh_days)

  @doc "How many remote replies one member may report per day."
  def report_limit, do: @note_report_limit

  @doc """
  Stores a reply somebody on another network wrote under a member's post
  (issues #1069 and #1071). `actor` is the fetched remote actor as
  `%{uri:, handle:, name:}`.

  This is the first time vutuv keeps a stranger's *words*, so every gate that
  must hold sits here, in order: the installation switch, the member federates,
  the member switched replies on (`users.fediverse_replies?`, off by default and
  deliberately separate from the reaction counts), the activity really carries a
  Note, that Note answers one of *their own* posts, the post is public, the
  sending server is within its inbound cap, and there is text left once the
  markup is gone. Anything else is `:skip` — the inbox answers the same 202
  either way, so a misdirected activity never learns which gate it failed.

  The note is stored as **plain text** (`Vutuv.RemoteHtml`), never HTML, and
  without any copy of the author's picture: the card renders initials and links
  to the origin.

  A redelivery of a note we already hold is a no-op; an author's edit arrives as
  an `Update` and goes through `update_reply/3`.
  """
  def record_reply(%User{} = user, activity, actor) do
    with true <- enabled?(),
         true <- federated?(user),
         true <- user.fediverse_replies?,
         %{} = object <- note_object(activity["object"]),
         %Post{} = post <- resolve_own_note(user, object["inReplyTo"]),
         false <- Posts.restricted?(post),
         :ok <- check_inbound_cap(actor.uri),
         {:ok, note} <- insert_note(user, post, activity, object, actor) do
      Posts.broadcast_post_counters(post.id)
      Activity.notify_fediverse_reply(user, post, note)
      :ok
    else
      _ -> :skip
    end
  end

  @doc """
  Applies an author's edit of a reply they already sent (`Update(Note)`).

  Scoped to the actor that wrote it, so one server cannot rewrite another's
  words, and it re-reads the audience: an author who narrows a public reply to
  their followers has said "stop showing this", and that has to take effect.
  """
  def update_reply(%User{} = user, activity, actor_uri) when is_binary(actor_uri) do
    with %{} = object <- note_object(activity["object"]),
         uri when is_binary(uri) <- object["id"],
         %Note{} = note <- Repo.get_by(Note, object_uri: uri, actor_uri: actor_uri),
         text when text != "" <- remote_text(object["content"], Note.max_content()) do
      note
      |> Note.changeset(%{
        content_text: text,
        summary: remote_text(object["summary"], Note.max_summary()),
        audience: audience(user, activity, object),
        checked_at: DateTime.utc_now(:second)
      })
      |> Repo.update()

      Posts.broadcast_post_counters(note.post_id)
    end

    :ok
  end

  def update_reply(_user, _activity, _actor_uri), do: :ok

  @doc """
  Honours an upstream `Delete` of a reply.

  Deliberately **un**gated, like `remove_reaction/4`: an author withdrawing their
  words is the deletion path that makes storing them defensible in the first
  place, so it must not depend on any switch still being on. Scoped to the actor
  that wrote the note, so one server cannot delete another's.
  """
  def delete_reply(actor_uri, object_uri)
      when is_binary(actor_uri) and is_binary(object_uri) do
    post_ids =
      Repo.all(
        from(n in Note,
          where: n.object_uri == ^object_uri and n.actor_uri == ^actor_uri,
          select: n.post_id
        )
      )

    if post_ids != [] do
      Repo.delete_all(from(n in Note, where: n.object_uri == ^object_uri))
      Enum.each(post_ids, &Posts.broadcast_post_counters/1)
    end

    :ok
  end

  def delete_reply(_actor_uri, _object_uri), do: :ok

  @doc """
  The stored replies for `post_ids`, grouped by post id, oldest first — what the
  thread renderer interleaves among the vutuv replies.

  **Viewer-scoped** (issue #1071): a public reply is for everyone, anything else
  only ever reaches the member whose post it answers, signed in. This is the one
  read the pages use, so the visibility rule cannot be forgotten at a call site.
  """
  def list_notes(post_ids, viewer) do
    from(n in notes_with_account(),
      join: p in Post,
      on: p.id == n.post_id,
      where: n.post_id in ^post_ids,
      where: n.audience == "public" or p.user_id == ^note_viewer_id(viewer),
      order_by: [asc: n.received_at, asc: n.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.post_id)
  end

  # Notes carrying `account_id`: whether we hold a row for the actor who wrote
  # one, which is what decides whether the card's handle links to their page
  # here or out to their own server (issue #1162). A LEFT join by URI rather
  # than a foreign key, because a note may well be older than the account row
  # and the row goes again by itself once nothing refers to it.
  #
  # **Every** loader of a note reads through this. The same card is rendered
  # from a list on the permalink and from a single row on the reply page, and a
  # handle that led two different places depending on which loader fetched it
  # would be nobody's decision and nothing's test.
  defp notes_with_account do
    from(n in Note,
      left_join: a in RemoteAccount,
      on: a.actor_uri == n.actor_uri,
      select: %{n | account_id: a.id}
    )
  end

  @doc """
  How many replies from other networks a post carries **publicly**.

  Public notes only, on purpose: a reply addressed to the member alone must not
  move a figure anybody else can read, or the count itself leaks that a private
  message exists.
  """
  def note_count(post_id) do
    Repo.aggregate(
      from(n in Note, where: n.post_id == ^post_id and n.audience == "public"),
      :count
    )
  end

  @doc "One stored reply, or nil."
  def get_note(id) do
    UUIDv7.with_cast(id, fn uuid ->
      Repo.one(from(n in notes_with_account(), where: n.id == ^uuid))
    end)
  end

  @doc """
  The member takes a reply off their own post. Deletes it at once and records
  the takedown in `Vutuv.Fediverse.NoteEvent`.

  Nothing leaves the building: removing a reply from your own post is a decision
  about *your* page, not an accusation, so the origin server is not told. Saying
  "this is not appropriate" is `report_note/2`, which does tell them.
  """
  def remove_note(note_id, %User{} = actor) do
    with {:ok, _note, _author_id} <-
           take_down_note(note_id, actor, "removed_by_member", &note_owner?/3),
         do: :ok
  end

  @doc """
  Somebody marks a reply as not appropriate. **Deletes it immediately** — there
  is no case workflow and no freezer, because unlike a member's own post this is
  a cache of something that still exists at its origin, so removing it costs the
  author nothing they did not keep.

  And because it still exists there, the report also goes **out**: a `Flag` to the
  origin server's inbox (issue #1102), which is how these networks file a report
  with each other. Deleting our cached copy alone left the original up with its
  moderators never learning anybody had objected.

  Rate limited per reporter (`report_limit/0` a day), so quietly wiping every
  answer under somebody's post is not free — and since the `Flag` only rides a
  successful takedown, that same cap bounds how many reports one member can push
  onto other servers. A private reply can only be reported by the member it was
  addressed to, since nobody else may even see it.
  """
  def report_note(note_id, %User{} = reporter) do
    case RateLimiter.hit(
           {:fediverse_note_report, reporter.id},
           @note_report_limit,
           :timer.hours(24)
         ) do
      :ok ->
        with {:ok, note, author_id} <-
               take_down_note(note_id, reporter, "reported", &note_visible?/3) do
          flag_note(note, author_id, reporter)
          :ok
        end

      _ ->
        {:error, :rate_limited}
    end
  end

  # Files the report with the server the reply came from (issue #1102).
  #
  # Signed by the member whose post the reply sat under, never by the reporter.
  # A `Flag` is a signed statement, so it has to come from an actor we serve a
  # key for, and vutuv has no installation-wide actor to file from (Mastodon uses
  # its instance actor for exactly this). The thread's owner is the party that
  # server already knows in this conversation, and using them keeps a bystander
  # reporter out of a message that travels to strangers: nothing in the `Flag`
  # names who reported it, and no content rides along — the reported object's own
  # id is the whole reference.
  #
  # Skipped when the note carried no answerable inbox (`own_inbox/1` refuses an
  # inbox on a host the actor does not control), when the post's author never
  # federated (no key to sign with), or when the operator has blocked that server
  # — a block is both ears and mouth shut.
  defp flag_note(%Note{} = note, author_id, %User{} = reporter) do
    with inbox when is_binary(inbox) <- note.inbox_uri,
         %User{} = author <- Repo.get(User, author_id),
         true <- ever_federated?(author),
         false <- instance_blocked?(note.actor_uri) do
      enqueue(author, [inbox], Docs.flag_activity(author, note.object_uri, note.actor_uri))
      log_note_event(note, author_id, reporter, "flagged")
      :ok
    else
      _ -> :skip
    end
  end

  @doc """
  Drops every remote reply stored under a member's posts — what switching the
  replies off means. Nothing is kept "just in case": the switch is the member's
  deletion lever over third-party data they never asked for.
  """
  def drop_notes(%User{id: user_id}) do
    {count, _} =
      Repo.delete_all(
        from(n in Note,
          where:
            n.post_id in subquery(from(p in Post, where: p.user_id == ^user_id, select: p.id))
        )
      )

    count
  end

  @doc """
  Deletes every stored reply past its ceiling — the floor under everything else,
  so a copy nobody looked at and no server told us about still goes.
  """
  def expire_due_notes(now \\ nil), do: expire_due(Note, now)

  # The ceiling enforcement itself, one copy for every kind of cached remote
  # content: everything that carries an `expires_at` goes when its clock runs
  # out, whatever else did or did not happen to it.
  defp expire_due(schema, now) do
    now = now || DateTime.utc_now(:second)
    due = where(schema, [r], r.expires_at <= ^now)

    # A cached post takes its pictures' files with it (issue #1163); a reply has
    # none, so this is a no-op for the other caller.
    if schema == RemotePost, do: wipe_media(due)

    {count, _} = Repo.delete_all(due)
    count
  end

  @doc """
  Which of `notes` should have their origin asked again — the lazy on-view
  freshness check (issue #1069).

  **Public notes only.** A reply addressed to the member alone answers `403` or
  `404` to any fetch we can make, which `refresh_note/1` would read as "deleted
  upstream" and act on, quietly destroying every private reply about a week
  after it arrived; and asking would tell the origin server that we are sitting
  on their member's private message, and how often we look at it. Those are
  governed by the ceiling and an upstream `Delete` alone.
  """
  def due_for_refresh(notes) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -note_refresh_days() * 86_400)

    Enum.filter(notes, fn note ->
      Note.public?(note) and
        (is_nil(note.checked_at) or DateTime.compare(note.checked_at, cutoff) == :lt)
    end)
  end

  @doc """
  Asks a note's origin whether it is still published there, and acts on the
  answer. The half of retention that deletes *earlier* than the ceiling, and the
  half that keeps the word "cache" honest.

  `200` and still public refreshes the text and pushes the ceiling out (a copy
  confirmed live last week has a far better claim to being necessary than one
  that is merely young). `404`, `410` and `403` delete at once — gone, or the
  author locked their account, which is equally a "stop showing this" signal we
  would otherwise never see. **Anything else changes nothing**, so a server that
  stays offline cannot buy indefinite retention and a three-week outage cannot
  trigger a mass delete.
  """
  def refresh_note(%Note{} = note) do
    with true <- enabled?(),
         true <- Note.public?(note),
         %Post{} = post <- Repo.get(Post, note.post_id),
         %User{} = author <- Repo.get(User, post.user_id) do
      apply_refresh(note, fetch_remote_note(note.object_uri, signer(author)))
    else
      _ -> :skip
    end
  end

  @doc """
  Runs `refresh_note/1` for every due note in the background, so a page render
  never waits on a stranger's server. Returns immediately.

  Off in tests (`:fediverse_note_refresh`), like every other background job that
  talks to the network: the task runs outside the SQL sandbox's ownership, so it
  would crash there — silently, since a Task's crash is only logged. Tests call
  `refresh_note/1` directly with a stubbed HTTP layer instead.
  """
  def refresh_async(notes) do
    with true <- Application.get_env(:vutuv, :fediverse_note_refresh, true),
         [_ | _] = due <- due_for_refresh(notes) do
      Task.Supervisor.start_child(Vutuv.TaskSupervisor, fn ->
        Enum.each(due, &refresh_note/1)
      end)
    end

    :ok
  end

  @doc """
  What each remote server has stored here as replies, biggest first — the other
  half of the operator's `/admin/fediverse` picture beside `inbound_hosts/1`.
  """
  def note_hosts(limit \\ 20) do
    Repo.all(
      from(n in Note,
        group_by: uri_host(n.actor_uri),
        order_by: [desc: count(n.id)],
        limit: ^limit,
        select: %{host: uri_host(n.actor_uri), notes: count(n.id)}
      )
    )
  end

  @doc """
  The most recent member takedowns of remote replies, newest first — the log an
  operator reads before deciding whether one troll or a whole server is the
  problem. Carries no content and no URIs by construction (see
  `Vutuv.Fediverse.NoteEvent`).
  """
  def recent_note_events(limit \\ 25) do
    Repo.all(from(e in NoteEvent, order_by: [desc: e.id], limit: ^limit))
  end

  @doc "How many remote replies are stored across the installation."
  def note_total, do: Repo.aggregate(Note, :count)

  # An activity delivers what it claims, or it is dropped: a Create whose object
  # is a bare id is not worth an outbound request to a stranger's server.
  defp note_object(%{"type" => "Note"} = object), do: object
  defp note_object(_), do: nil

  defp insert_note(user, post, activity, object, actor) do
    uri = object["id"]
    text = remote_text(object["content"], Note.max_content())
    received = DateTime.utc_now(:second)

    cond do
      not is_binary(uri) or uri == "" ->
        :error

      # Nothing left once the markup is gone (a picture-only or empty note): a
      # row about a third party has to earn its place.
      text in [nil, ""] ->
        :error

      Repo.exists?(from(n in Note, where: n.object_uri == ^uri)) ->
        :error

      true ->
        %Note{post_id: post.id}
        |> Note.changeset(%{
          object_uri: uri,
          actor_uri: actor.uri,
          origin_url: presence(object["url"]),
          in_reply_to_uri: object["inReplyTo"],
          inbox_uri: own_inbox(actor),
          handle: actor.handle,
          display_name: actor.name,
          content_text: text,
          summary: remote_text(object["summary"], Note.max_summary()),
          audience: audience(user, activity, object),
          received_at: received,
          # It was demonstrably published the moment it was delivered, so the
          # delivery is the first freshness confirmation.
          checked_at: received,
          expires_at: DateTime.add(received, note_retention_days() * 86_400)
        })
        |> Repo.insert()
    end
  end

  @doc """
  The inbox a remote actor may be answered at: their own, and only when it sits
  on the **same host** as the actor id (issue #1070).

  An actor document names its own inbox, and that document is written by whoever
  runs the server. A hostile one can point its inbox at a third party and use a
  member's reply to make vutuv deliver a signed POST there, which is the classic
  ActivityPub inbox redirect. The inbox path already refuses a `keyId` served by
  another host (`same_authority?/2` in `VutuvWeb.FediverseController`); this is
  the same rule for the delivery target.

  Returns `nil` when the document names a foreign, malformed or missing inbox, so
  the answer is simply not delivered to it rather than delivered somewhere the
  actor does not control.
  """
  def own_inbox(%{uri: actor_uri, inbox: inbox}) when is_binary(inbox) do
    if same_host?(actor_uri, inbox), do: inbox
  end

  def own_inbox(_actor), do: nil

  defp same_host?(a, b) when is_binary(a) and is_binary(b) do
    case {URI.parse(a), URI.parse(b)} do
      {%URI{host: host}, %URI{host: host, scheme: "https"}} when is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp same_host?(_a, _b), do: false

  # How the note was addressed, read from `to`/`cc` on **both** the Create and
  # the Note (servers put the audience on either). Only the public collection
  # makes it public; everything else, including anything we cannot read, renders
  # to the addressed member alone. Never widen the sender's audience.
  defp audience(user, activity, object) do
    addressed =
      [object["to"], object["cc"], activity["to"], activity["cc"]]
      |> Enum.flat_map(&normalize_uri_list/1)

    cond do
      Enum.any?(addressed, &(&1 in @public_collections)) -> "public"
      Enum.any?(addressed, &String.ends_with?(&1, @followers_suffix)) -> "followers"
      Docs.actor_url(user) in addressed -> "direct"
      true -> "unknown"
    end
  end

  defp remote_text(nil, _max), do: nil

  defp remote_text(html, max) when is_binary(html), do: presence(RemoteHtml.to_text(html, max))

  defp remote_text(_html, _max), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  # The nil UUID can never match a row: "not the author" without a NULL arm,
  # the same trick `Vutuv.Posts.engagement_viewer_id/1` uses.
  defp note_viewer_id(%User{id: id}), do: id
  defp note_viewer_id(id) when is_binary(id), do: id
  defp note_viewer_id(_), do: "00000000-0000-0000-0000-000000000000"

  # Only the member whose post it sits under (or an admin) may remove a reply.
  defp note_owner?(_note, author_id, %User{} = actor),
    do: actor.id == author_id or actor.admin? == true

  # Anyone who can see it may report it, which for a private reply is its
  # addressee alone.
  defp note_visible?(note, author_id, %User{} = actor),
    do: Note.public?(note) or note_owner?(note, author_id, actor)

  defp take_down_note(note_id, %User{} = actor, action, authorized?) do
    query =
      from(n in Note,
        join: p in Post,
        on: p.id == n.post_id,
        where: n.id == ^to_string(note_id),
        select: {n, p.user_id}
      )

    case UUIDv7.with_cast(note_id, fn _ -> Repo.one(query) end) do
      {%Note{} = note, author_id} ->
        if authorized?.(note, author_id, actor) do
          Repo.delete(note)
          log_note_event(note, author_id, actor, action)
          Posts.broadcast_post_counters(note.post_id)
          # The deleted row is handed back so the caller can still address the
          # origin server (`flag_note/3`) — after this it is the only copy of
          # that address left.
          {:ok, note, author_id}
        else
          {:error, :not_allowed}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp log_note_event(%Note{} = note, author_id, %User{} = actor, action) do
    log_takedown(%{
      action: action,
      host: Note.host(note.actor_uri) || "unknown",
      actor_uri: note.actor_uri,
      audience: note.audience,
      user_id: author_id,
      actor_id: actor.id
    })
  end

  # The one writer of the content-free takedown ledger, so its field set — and
  # the keyed digest that stands in for the actor — has a single definition
  # whatever kind of cached content was taken down. `user_id` is the member
  # whose page it sat on, and is absent for content that sat on nobody's (a
  # cached post from a followed account, issue #1161).
  defp log_takedown(attrs) do
    Repo.insert!(%NoteEvent{
      action: attrs.action,
      host: attrs.host,
      actor_digest: note_actor_digest(attrs.actor_uri),
      audience: attrs.audience,
      user_id: attrs[:user_id],
      actor_id: attrs.actor_id
    })
  end

  # A keyed HMAC, not a bare hash: it groups a repeat offender across takedowns
  # without keeping an online identifier of somebody whose words we just
  # deleted, and a DB or backup leak alone cannot turn it back into the actor
  # URI. Same pepper construction as the invitation and login-PIN hashes.
  defp note_actor_digest(actor_uri) do
    :hmac
    |> :crypto.mac(:sha256, note_actor_pepper(), actor_uri)
    |> Base.encode16(case: :lower)
  end

  defp note_actor_pepper do
    secret = Application.fetch_env!(:vutuv, VutuvWeb.Endpoint)[:secret_key_base]
    :crypto.hash(:sha256, "vutuv/fediverse_note_actor/pepper/v1" <> secret)
  end

  defp apply_refresh(%Note{} = note, {:ok, doc}) do
    text = remote_text(doc["content"], Note.max_content())
    still_public? = doc_public?(doc)

    cond do
      # The author narrowed the audience: the same "stop showing this" signal a
      # 403 carries, just visible to us.
      not still_public? ->
        delete_note_row(note)
        :deleted

      text in [nil, ""] ->
        delete_note_row(note)
        :deleted

      true ->
        now = DateTime.utc_now(:second)

        note
        |> Note.changeset(%{
          content_text: text,
          summary: remote_text(doc["summary"], Note.max_summary()),
          checked_at: now,
          expires_at: DateTime.add(now, note_retention_days() * 86_400)
        })
        |> Repo.update()

        :refreshed
    end
  end

  defp apply_refresh(%Note{} = note, {:gone, status}) do
    Logger.info("fediverse note #{note.id} gone upstream (#{status}), deleting")
    delete_note_row(note)
    :deleted
  end

  # Unreachable, a 5xx, a 429, a malformed body: not fresh, but not evidence of
  # anything either. Nothing changes, so the ceiling still governs.
  defp apply_refresh(%Note{}, _other), do: :unchanged

  # By id, not by struct: `refresh_async/1` is fire-and-forget and undeduped, so
  # two page renders can queue a check for the same note and both conclude it is
  # gone. `Repo.delete/1` on the loser's stale struct raises
  # `Ecto.StaleEntryError` — inside a Task, where it would only ever be logged.
  # Deleting by id is simply a no-op the second time.
  defp delete_note_row(%Note{} = note) do
    Repo.delete_all(from(n in Note, where: n.id == ^note.id))
    Posts.broadcast_post_counters(note.post_id)
  end

  # A refetched note counts as public only if it still addresses the public
  # collection; anything else (including an answer we cannot parse) is a signal
  # to stop showing it, never a reason to keep it.
  defp doc_public?(doc) do
    [doc["to"], doc["cc"]]
    |> Enum.flat_map(&normalize_uri_list/1)
    |> Enum.any?(&(&1 in @public_collections))
  end

  # The same https-only, SSRF-guarded, size-capped, signed GET
  # `fetch_remote_actor/2` uses — pointed at a note instead of an actor.
  defp fetch_remote_note(uri, signer) do
    with {:parse, %URI{scheme: "https", host: host}} <- {:parse, URI.parse(uri)},
         {:ssrf, false} <- {:ssrf, Vutuv.Ssrf.resolves_to_internal?(host)},
         {:ok, %Req.Response{status: 200, body: body}} <- ap_get(uri, signer),
         {:size, true} <- {:size, byte_size(body) <= @max_body_bytes},
         {:ok, %{} = doc} <- Jason.decode(body) do
      {:ok, doc}
    else
      {:ok, %Req.Response{status: status}} when status in [403, 404, 410] -> {:gone, status}
      other -> {:error, other}
    end
  end

  ## Account migration — move out (issue #986, half 2)

  @move_cooldown_days 30

  @doc "How long (days) a member must wait between Move broadcasts."
  def move_cooldown_days, do: @move_cooldown_days

  @doc "Whether the member has redirected their Fediverse followers elsewhere."
  def moved?(%User{moved_to: nil}), do: false
  def moved?(%User{moved_to: moved_to}), do: is_binary(moved_to)

  @doc """
  Redirects the member's Fediverse followers to another account (`Move`).

  Fetches the target actor and checks it lists this member's vutuv actor in its
  own `alsoKnownAs` — the same guarantee every remote server demands before it
  honors a Move, so a move the network would silently ignore fails fast here
  instead. On success it stamps `moved_to`/`moved_at`, broadcasts
  `Move { actor, object, target }` to every follower inbox (compliant servers
  re-point their follow to the target), and from then on the member's new posts
  stop federating (`moved?/1` gate above) while the actor keeps serving the
  `movedTo` redirect. The vutuv profile itself is untouched — this is a redirect,
  not a deletion or a logout.

  Returns `{:ok, user}` or `{:error, reason}` where reason is one of
  `:not_federated`, `:cooldown`, `:invalid_target`, `:self_target`,
  `:alias_missing`, `:target_unreachable`.
  """
  def move_out(%User{} = user, target_input) do
    with true <- (enabled?() and federated?(user)) or {:error, :not_federated},
         :ok <- check_move_cooldown(user),
         {:ok, target_id} <- resolve_move_target(user, target_input),
         {:ok, moved} <- store_move(user, target_id) do
      broadcast_move(moved, target_id)
      {:ok, moved}
    end
  end

  @doc """
  Cancels a redirect: clears `moved_to` so the member federates new posts again
  and the actor stops advertising `movedTo`. `moved_at` is deliberately kept, so
  the re-move cooldown still holds — cancelling must not be a way to spam moves.
  Followers a remote server already re-pointed do not come back automatically
  (a Fediverse reality, not something vutuv can reverse).
  """
  def cancel_move(%User{} = user) do
    user |> Ecto.Changeset.change(moved_to: nil) |> Repo.update()
  end

  # nil moved_at = never moved; otherwise block until the cooldown has elapsed.
  defp check_move_cooldown(%User{moved_at: nil}), do: :ok

  defp check_move_cooldown(%User{moved_at: moved_at}) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -@move_cooldown_days * 86_400, :second)
    if NaiveDateTime.compare(moved_at, cutoff) == :gt, do: {:error, :cooldown}, else: :ok
  end

  # Resolve the target to its canonical actor id and confirm it names us as an
  # alias. A bare/non-https string never reaches the network (fetch_remote_actor
  # would reject it, but a clean :invalid_target message is friendlier).
  defp resolve_move_target(user, target_input) do
    my_actor = Docs.actor_url(user)

    with {:input, %URI{scheme: "https", host: h}} when is_binary(h) and h != "" <-
           {:input, URI.parse(to_string(target_input))},
         {:fetch, {:ok, remote}} <- {:fetch, fetch_remote_actor(target_input, signer(user))} do
      cond do
        remote.id == my_actor -> {:error, :self_target}
        my_actor in remote.also_known_as -> {:ok, remote.id}
        true -> {:error, :alias_missing}
      end
    else
      {:input, _} -> {:error, :invalid_target}
      {:fetch, _} -> {:error, :target_unreachable}
    end
  end

  defp store_move(user, target_id) do
    user
    |> Ecto.Changeset.change(
      moved_to: target_id,
      moved_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
    )
    |> Repo.update()
  end

  defp broadcast_move(user, target_id) do
    case delivery_inboxes(user) do
      [] -> :ok
      inboxes -> enqueue(user, inboxes, Docs.move_activity(user, target_id))
    end
  end

  # The member's own key, to sign the target-actor fetch (authorized-fetch
  # instances reject anonymous GETs). federated?/1 guaranteed the actor exists.
  defp signer(user), do: signer_for(user, get_actor(user))

  ## Answering another network (issue #1070)

  @doc """
  Whether `author` may answer the stored remote reply `note`, and when not, which
  gate refused. `:ok`, or `{:error, reason}` with one of:

    * `:fediverse_disabled` — the installation switch is off.
    * `:note_not_public` — the reply was addressed to the member alone. Answering
      it would mean publishing half of a private exchange, so v1 does not offer
      it at all; the card links to the original instead.
    * `:not_federating` — the member has not switched Fediverse participation on
      (or their account is not in good standing). **The one refusal the member can
      do something about**, which is why it is named separately: the reply page
      turns it into an explanation and a link to `/settings/fediverse` rather than
      a dead end.
    * `:moved` — the member redirected their Fediverse followers to another
      account, so nothing of theirs federates any more.
    * `:instance_blocked` — the operator shut that server out. A block is both
      ears and mouth shut, so it stops answers going the other way too.

  Any federating member may answer, not only the author of the post the note sits
  under: the conversation is on their post either way, and an answer is delivered
  from the answerer's own actor to their own followers.

  Deliberately free of side effects, so a render can ask it as safely as a write.
  The outbound budget is claimed separately (`claim_reply_budget/1`).
  """
  def check_remote_reply(%User{} = author, %Note{} = note) do
    cond do
      not enabled?() -> {:error, :fediverse_disabled}
      not Note.public?(note) -> {:error, :note_not_public}
      not federated?(author) -> {:error, :not_federating}
      moved?(author) -> {:error, :moved}
      instance_blocked?(note.actor_uri) -> {:error, :instance_blocked}
      true -> :ok
    end
  end

  @doc """
  Whether `user` may answer the cached post `post` (issue #1165), and when not,
  which gate refused. The same vocabulary `check_remote_reply/2` answers in, so
  one wording table covers both, plus one gate of its own:

    * `:post_not_public` — the author published it to their followers only. The
      answer would be a **public vutuv post** quoting a restricted context, and
      republishing the audience somebody chose is not ours to do, so v1 offers no
      Reply there at all rather than a control that refuses.

  Everything after that is the like path's gate unchanged (`check_remote_like/2`
  and its `:not_visible`), which is why the two share it: the same member-side
  switches, the same blocklist and the same "is this theirs to see" question.

  Free of side effects. The budget (`claim_reply_budget/1`) is the reply path's,
  shared deliberately: both are the same act — a member's own words leaving for
  a server that never followed them — and metering them separately would let one
  member's hour of answering hide inside the other's budget.
  """
  def check_remote_post_reply(%User{} = user, %RemotePost{} = post) do
    # The audience question first, and then nothing of its own: every other gate
    # is the like path's, asked in the same order (`check_remote_post_act/2`).
    # A followers-only post is refused whatever the member's own settings say,
    # since no setting of theirs could ever make it answerable.
    if RemotePost.open?(post),
      do: check_remote_post_act(user, post),
      else: {:error, :post_not_public}
  end

  @doc """
  Claims one slot from the member's hourly budget for answers that leave for
  another network. `:ok`, or `{:error, :reply_capped}`.

  This is the one place a member's own action makes vutuv POST to a server that
  never followed them, so it is metered. The shape of the feature already bounds
  it hard (an answer needs a stored reply on a vutuv post first, so the targets
  are people who wrote here, never a list an attacker picks), and this is the
  backstop for the rest: a compromised account cannot turn the installation into
  a relay faster than the budget allows.

  Consuming, so only the write path calls it.
  """
  def claim_reply_budget(%User{id: user_id}) do
    case RateLimiter.hit(
           {:fediverse_outbound_reply, user_id},
           outbound_reply_limit(),
           @inbound_window_ms
         ) do
      :ok -> :ok
      _ -> {:error, :reply_capped}
    end
  end

  @doc "How many answers per hour one member may send to other networks."
  def outbound_reply_limit,
    do: Application.get_env(:vutuv, :fediverse_outbound_reply_limit, @outbound_reply_limit)

  ## Liking a post on another network (issue #1164)

  @doc """
  Whether `user` may like the cached post `post`, and when not, which gate
  refused (the `check_remote_reply/2` vocabulary, minus the one that does not
  apply):

    * `:fediverse_disabled` — the installation switch is off.
    * `:not_federating` — the member has not switched Fediverse participation on.
      The `Like` is signed with their own actor key, so there is no such thing
      as an actorless like. The one refusal they can do something about.
    * `:moved` — they redirected their Fediverse identity elsewhere.
    * `:instance_blocked` — the operator shut that server out, in both
      directions.
    * `:not_visible` — the post is not one this member may read.

  Deliberately **no follow requirement**, and just as deliberately not "no check
  at all": a follow is the wrong question, because the account page shows an
  account's public posts to any signed-in member, follower or not
  (`account_posts/2`), and liking what you are shown has to work there. The
  right question is whether the post is one they may read, which is what
  `remote_post_readable?/2` asks in the same vocabulary that query uses. The
  id in a click is attacker-controlled, so this cannot be left to the fact that
  the LiveView resolves it against its own rendered list.

  Free of side effects, so a render may ask it. The budget is claimed separately.
  """
  def check_remote_like(%User{} = user, %RemotePost{} = post),
    do: check_remote_post_act(user, post)

  # What both outbound acts on a cached post ask, in one place: the installation
  # switch, the member's own Fediverse standing (they sign with their own key,
  # so there is no actorless like or answer), the operator blocklist — a block
  # shuts both directions — and whether this is a post they may read at all,
  # since the id in a click is attacker-controlled. Answering adds its own
  # audience gate on top; liking has none.
  defp check_remote_post_act(%User{} = user, %RemotePost{} = post) do
    cond do
      not enabled?() -> {:error, :fediverse_disabled}
      not federated?(user) -> {:error, :not_federating}
      moved?(user) -> {:error, :moved}
      instance_blocked?(actor_uri_of(post)) -> {:error, :instance_blocked}
      not remote_post_readable?(post, user) -> {:error, :not_visible}
      true -> :ok
    end
  end

  @doc """
  Whether `viewer` may read this cached post: an open audience is readable by
  any signed-in member (that is what the account page shows), and a
  followers-only one needs their own accepted follow.

  The read half of what `account_posts/2` enforces in SQL, for a caller holding
  a post rather than a query. `remote_post_visible?/2` beside it answers the
  narrower feed question ("would this reach them unprompted"), which also
  requires a follow — the two are different questions and must not be merged.
  """
  def remote_post_readable?(%RemotePost{} = post, %User{id: viewer_id}) do
    RemotePost.open?(post) or
      Repo.exists?(
        from(f in Follow,
          where:
            f.user_id == ^viewer_id and f.remote_account_id == ^post.remote_account_id and
              f.state == "accepted"
        )
      )
  end

  def remote_post_readable?(_post, _viewer), do: false

  @doc """
  Claims one slot from the member's hourly like budget. `:ok`, or
  `{:error, :like_capped}`.

  Consuming, so only the write path calls it — and only the **like** path: an
  unlike is a withdrawal, and refusing to let somebody take a like back because
  they have been busy would be an odd shape of limit.
  """
  def claim_like_budget(%User{id: user_id}) do
    case RateLimiter.hit(
           {:fediverse_outbound_like, user_id},
           outbound_like_limit(),
           @inbound_window_ms
         ) do
      :ok -> :ok
      _ -> {:error, :like_capped}
    end
  end

  @doc "How many likes per hour one member may send to other networks."
  def outbound_like_limit,
    do: Application.get_env(:vutuv, :fediverse_outbound_like_limit, @outbound_like_limit)

  @doc """
  The member likes a cached post: writes the local marker and queues a signed
  `Like` to the author's own inbox.

  `{:ok, :liked}`, `{:ok, :already}` when the marker was already there (a
  double tap, or a second tab — no second activity goes out), or the gate's
  `{:error, reason}`.

  The marker is written **first** and the activity queued after it, in that
  order on purpose: a queued activity whose marker failed to write would paint
  no heart while the author's server counts the like, which is the one
  disagreement a member cannot fix from here.
  """
  def like_remote_post(%User{} = user, %RemotePost{} = post) do
    # Re-read first. The card was rendered at some earlier moment and the row
    # can be gone by the time the heart is pressed — expiry, an upstream
    # `Delete`, another member's report, an instance block — and the insert
    # would then hit the foreign key and take the whole LiveView down with it.
    # `on_conflict: :nothing` suppresses the *unique* violation, never this one.
    with %RemotePost{} = post <- reload_remote_post(post),
         :ok <- check_remote_like(user, post) do
      case insert_post_like(user, post) do
        {:ok, :liked} -> send_like(user, post)
        other -> other
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # The budget is claimed here rather than before the insert, so a double tap or
  # a second tab — which writes nothing and sends nothing — does not spend
  # somebody's slot. A refusal rolls the marker back: a heart painted for a like
  # that never left is the one disagreement a member cannot fix from here.
  defp send_like(user, post) do
    case claim_like_budget(user) do
      :ok ->
        deliver_like(user, post, &Docs.like_activity/3)
        {:ok, :liked}

      {:error, _} = capped ->
        Repo.delete_all(
          from(l in PostLike, where: l.user_id == ^user.id and l.remote_post_id == ^post.id)
        )

        capped
    end
  end

  @doc """
  This cached post as it is **now**, keeping the account already in hand, or nil
  once the row is gone.

  Every write path that acts on a post a member is looking at goes through here
  first. A card is rendered at one moment and acted on at another, and in
  between the row can be deleted (expiry, an upstream `Delete`, another
  member's report, an instance block) or changed (its author narrowing the
  audience with an `Update`). Acting on the struct in hand means a foreign-key
  crash in the first case and a bypassed audience rule in the second.
  """
  def reload_remote_post(%RemotePost{id: id, remote_account: account}) do
    case Repo.get(RemotePost, id) do
      %RemotePost{} = post -> %{post | remote_account: account}
      nil -> nil
    end
  end

  @doc """
  The member takes the like back: drops the marker and queues the matching
  `Undo(Like)`.

  `{:ok, :unliked}` or `{:ok, :already}`. No gate and no budget — a withdrawal
  must not be refusable, and if the member has since stopped federating there
  is simply nothing to send, which `deliver_like/3` handles by finding no actor.
  """
  def unlike_remote_post(%User{} = user, %RemotePost{} = post) do
    {count, _} =
      Repo.delete_all(
        from(l in PostLike, where: l.user_id == ^user.id and l.remote_post_id == ^post.id)
      )

    if count > 0 do
      deliver_like(user, post, &Docs.undo_like_activity/3)
      {:ok, :unliked}
    else
      {:ok, :already}
    end
  end

  @doc """
  Which of `post_ids` this member already likes, as a `MapSet` — one query for a
  whole feed page rather than one per card.
  """
  def liked_remote_post_ids(%User{id: user_id}, post_ids) when is_list(post_ids) do
    from(l in PostLike,
      where: l.user_id == ^user_id and l.remote_post_id in ^post_ids,
      select: l.remote_post_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  def liked_remote_post_ids(_viewer, _post_ids), do: MapSet.new()

  # The join-row kernel every other engagement toggle here writes through
  # (`Vutuv.Engagement`), for the reason `insert_reaction/3` spells out:
  # `Repo.insert(on_conflict: :nothing)` cannot say whether the row landed,
  # because the v7 id is minted in Elixir and the struct comes back looking
  # identical either way, so only the inserted row count is an honest answer.
  # Here that answer decides whether an activity leaves the building. Nothing
  # needs a changeset — both ids come from records the caller already resolved.
  defp insert_post_like(user, post) do
    case Engagement.insert_if_new(
           PostLike,
           %{user_id: user.id, remote_post_id: post.id},
           [:user_id, :remote_post_id]
         ) do
      {:inserted, _row} -> {:ok, :liked}
      :exists -> {:ok, :already}
    end
  end

  # The author's own inbox, never the shared one: a Like is addressed to one
  # person, and a shared inbox is for what a server fans out to many.
  defp deliver_like(user, %RemotePost{} = post, builder) do
    with %RemoteAccount{} = account <- post_account(post),
         # `ever_federated?/1`, never `federated?/1`, for the reason the
         # revocation paths spell out (issue #1102): a withdrawal happens
         # exactly when the state that allowed the original act is already
         # gone. Gating the `Undo` on it would leave the favourite standing
         # under a member's name on a server they can no longer reach.
         true <- ever_federated?(user),
         inbox when is_binary(inbox) <- account.inbox_uri do
      enqueue(user, [inbox], builder.(user, account.actor_uri, post.object_uri))
    else
      _ -> :skip
    end
  end

  defp post_account(%RemotePost{remote_account: %RemoteAccount{} = account}), do: account
  defp post_account(%RemotePost{remote_account_id: id}), do: Repo.get(RemoteAccount, id)

  defp actor_uri_of(%RemotePost{} = post) do
    case post_account(post) do
      %RemoteAccount{actor_uri: uri} -> uri
      _ -> nil
    end
  end

  ## Federating posts (called from Vutuv.Posts after commit)

  @doc "A freshly published post -> Create(Note) to every follower inbox."
  def federate_new_post(%Post{} = post),
    do: maybe_federate(post, &Docs.create_activity/2, "post_create")

  @doc """
  An edited post -> Update(Note); one whose audience closed -> Delete, so
  remote copies follow the post out of public view (best effort — remote
  deletion is advisory by protocol).
  """
  def federate_post_update(%Post{} = post) do
    if Posts.restricted?(post) do
      revoke_post(post)
    else
      maybe_federate(post, &Docs.update_activity/2, "post_update")
    end
  end

  defp maybe_federate(%Post{} = post, builder, kind) do
    with true <- enabled?(),
         %User{} = user <- Repo.get(User, post.user_id),
         true <- federated?(user),
         false <- moved?(user),
         false <- Posts.restricted?(post),
         post = Repo.preload(post, Docs.note_preloads()),
         [_ | _] = inboxes <- recipients(user, post) do
      # Remember where this copy went and under which id, so the takedown can be
      # addressed rather than broadcast at whoever follows today (issue #1102).
      record_post_deliveries(user, post, inboxes)
      enqueue(user, inboxes, builder.(post, user), hold_opts(post, kind))
    else
      _ -> :skip
    end
  end

  ## Revocation: taking something back off the other servers (issue #1102)

  @doc """
  **The one revocation chokepoint.** Asks every server that received this post
  to drop its copy (`Delete(Tombstone)`), best effort.

  Called from every takedown path, so "taken down here" can never mean "still
  published there" for want of a call site: the owner's own delete
  (`Vutuv.Posts.delete_post/1`), an edit that closes the audience
  (`federate_post_update/1`), and the moderation freezer
  (`Vutuv.Moderation.freeze_content/1` — a trusted report, or the second one that
  upgrades a merely flagged case).

  **Addressed, not broadcast.** The recorded deliveries
  (`Vutuv.Fediverse.PostDelivery`) name the inboxes that actually received the
  post and the Note id it was published under, so the `Delete` reaches a server
  that has since unfollowed and still matches after a username change. A post
  with no records — published before those were kept — falls back to the old
  behaviour: the current follower inboxes and the current Note id, which is
  better than sending nothing.

  Gated on `ever_federated?/1`, not `federated?/1`, and with no `moved?/1` skip:
  see that function for why a takedown must not be blocked by the very state the
  takedown creates. Returns `:ok` or `:skip`.
  """
  def revoke_post(%Post{} = post) do
    with true <- enabled?(),
         %User{} = user <- Repo.get(User, post.user_id),
         true <- ever_federated?(user),
         [_ | _] = targets <- revocation_targets(user, post) do
      Enum.each(targets, fn {object_uri, inboxes} ->
        enqueue(user, inboxes, Docs.tombstone_activity(object_uri, user))
      end)

      # The addresses have done their job; a copy that comes back re-records
      # them (`republish_post/1`).
      forget_post_deliveries(post.id)
      :ok
    else
      _ -> :skip
    end
  end

  @doc """
  Publishes a post again after a **reversible** takedown was lifted — the other
  half of revoking on a freeze (issue #1102).

  A freeze hides the post from everyone but its owner, so the copies elsewhere
  have to go too or the freeze is a local fiction; and a rejected report has to
  put the post back where it was, here and there. It is a fresh `Create`, not an
  `Update`: the remote servers were told to delete the object, so there is
  nothing left there for an `Update` to change.

  Reads the post again rather than trusting the struct handed in: the callers
  clear `frozen_at` with an `update_all`, so their copy still looks frozen and
  the publish would gate itself away.
  """
  def republish_post(%Post{id: post_id}) do
    case Posts.get_post(post_id) do
      %Post{} = post -> maybe_federate(post, &Docs.create_activity/2, "post_create")
      _ -> :skip
    end
  end

  @doc """
  Tells the servers that follow this member their actor is gone
  (`Delete { object: <actor-url> }`) — the account-level revocation, for a
  **permanent** moderation removal: an admin's `remove_owner :deactivate` and the
  strike ladder's third strike (`Vutuv.Moderation`).

  Deliberately a broadcast and not a status code. `410 Gone` on the actor
  endpoints stays reserved for the member's own opt-out (`departed?/1`), and every
  *temporary* hiding — a freeze, a week's suspension — keeps answering `404` and
  sends nothing at all: a three-day suspension must never tell the network to
  delete the account. What makes these two paths different is that they do not
  come back.

  Unlike `prepare_actor_delete/1` this enqueues an ordinary delivery, because
  moderation leaves the account, its actor key and its follower rows in place —
  so the takedown gets the full retry ladder and, if it never arrives, the
  give-up ledger (`recent_delivery_failures/1`).
  """
  def revoke_actor(%User{} = user) do
    with true <- enabled?(),
         true <- ever_federated?(user),
         [_ | _] = inboxes <- actor_delete_inboxes(user) do
      enqueue(user, inboxes, Docs.actor_delete_activity(user))
    else
      _ -> :skip
    end
  end

  # Everybody who has to hear that this actor is gone: the servers that follow
  # the member (so their copies go) and — since issue #1160 — the servers whose
  # accounts the member follows, so they stop delivering to an inbox that no
  # longer answers.
  defp actor_delete_inboxes(%User{} = user) do
    (delivery_inboxes(user) ++ followed_inboxes(user)) |> Enum.uniq()
  end

  @doc """
  Drops every recorded post delivery for a member — called by the account
  deletion chokepoint (`Vutuv.Accounts.delete_user/1`).

  The rows carry no foreign key into `posts` (a revocation has to outlive the post
  row), so the cascade cannot clear them and the deletion says so explicitly. The
  member's actor `Delete` covers the copies themselves: it asks remote servers to
  purge the actor **and** its posts, which is why nothing is revoked per post here.
  """
  def drop_post_deliveries(%User{id: user_id}) do
    {count, _} = Repo.delete_all(from(d in PostDelivery, where: d.user_id == ^user_id))
    count
  end

  @doc """
  The takedowns that never arrived, newest first — a `Delete` or `Flag` dropped
  after the last attempt. The operator's list on `/admin/fediverse`, so an
  incomplete takedown is not just a line in the log.
  """
  def recent_delivery_failures(limit \\ 25) do
    Repo.all(from(f in DeliveryFailure, order_by: [desc: f.id], limit: ^limit))
  end

  @doc "How many takedowns gave up without arriving."
  def delivery_failure_count, do: Repo.aggregate(DeliveryFailure, :count)

  # Where a post's copies are, as `[{published_note_id, inboxes}]`. Grouped by
  # the id rather than flattened, because an `Update` sent after a rename
  # published a second id and both copies have to be named.
  defp revocation_targets(%User{} = user, %Post{} = post) do
    case recorded_post_deliveries(post.id) do
      [] -> fallback_targets(user, post)
      recorded -> recorded
    end
  end

  defp recorded_post_deliveries(post_id) do
    from(d in PostDelivery,
      where: d.post_id == ^post_id,
      select: {d.object_uri, d.inbox_uri}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {object_uri, inboxes} -> {object_uri, Enum.uniq(inboxes)} end)
  end

  # Nothing recorded: a post from before the records existed. The current
  # followers and the current Note id are a worse address than the real one, and
  # a much better one than silence.
  defp fallback_targets(%User{} = user, %Post{} = post) do
    case recipients(user, post) do
      [] -> []
      inboxes -> [{Docs.note_url(user, post.id), inboxes}]
    end
  end

  defp record_post_deliveries(%User{} = user, %Post{} = post, inboxes) do
    object_uri = Docs.note_url(user, post.id)
    stamp = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    rows =
      Enum.map(inboxes, fn inbox ->
        %{
          id: UUIDv7.generate(),
          post_id: post.id,
          user_id: user.id,
          inbox_uri: inbox,
          object_uri: object_uri,
          inserted_at: stamp
        }
      end)

    Repo.insert_all(PostDelivery, rows,
      on_conflict: :nothing,
      conflict_target: [:post_id, :inbox_uri, :object_uri]
    )
  end

  defp forget_post_deliveries(post_id) do
    Repo.delete_all(from(d in PostDelivery, where: d.post_id == ^post_id))
  end

  ## Holding a post back until its pictures are vetted (issue #1070)

  @doc """
  How long a post with an unvetted picture waits before it federates anyway.

  A post's images are invisible until the AI scan releases them
  (`Vutuv.Moderation.ImageScans`), so a Note built the instant the post commits
  carries no attachment for them and nothing would ever send the picture. The
  post is therefore held, and released the moment the scan settles — usually a few
  seconds later, through `images_settled/1`.

  This is the **ceiling**, not the normal wait: it is what happens when the
  scanner is down, and then the post goes out without the picture rather than not
  at all. Configurable (`:fediverse_image_hold_seconds`) so tests do not sit on a
  real clock.
  """
  def image_hold_seconds,
    do: Application.get_env(:vutuv, :fediverse_image_hold_seconds, @image_hold_seconds)

  # A post with nothing pending goes out now, exactly as before. One waiting on a
  # picture is enqueued with a complete, valid activity anyway (so a release that
  # knows nothing of `rebuild_from` still delivers something sane) plus the marker
  # that tells this release to re-render it at send time.
  defp hold_opts(%Post{} = post, kind) do
    if Posts.awaiting_image_release?(post) do
      [
        delay_seconds: image_hold_seconds(),
        rebuild_from: "#{kind}:#{post.id}"
      ]
    else
      []
    end
  end

  @doc """
  The AI scan settled every picture on this post: send any held delivery now
  instead of waiting out `image_hold_seconds/0`.

  Called from `Vutuv.Moderation.ImageSubjects` on both outcomes, because a
  rejected picture settles the post just as an approved one does — the post then
  federates without it, which is the whole point of vetting first.

  Nothing to do when a *second* picture on the same post is still pending: the
  post waits for the last one.
  """
  def images_settled(post_id) when is_binary(post_id) do
    if enabled?() and not Posts.awaiting_image_release?(post_id) do
      release_held_deliveries(post_id)
    end

    :ok
  end

  def images_settled(_post_id), do: :ok

  defp release_held_deliveries(post_id) do
    now = DateTime.utc_now(:second)
    markers = Enum.map(["post_create", "post_update"], &"#{&1}:#{post_id}")

    {count, _} =
      from(d in Delivery, where: d.rebuild_from in ^markers and d.next_attempt_at > ^now)
      |> Repo.update_all(set: [next_attempt_at: now])

    if count > 0, do: Deliverer.nudge()
    count
  end

  @doc """
  Every inbox one of a member's post activities goes to: the servers that
  followed them, plus — when the post answers a reply from another network
  (issue #1070) — the inbox of the person answered.

  That last one is the only inbox vutuv ever posts to without having been asked,
  which is why the address is vetted before it is ever stored (`own_inbox/1`
  refuses an inbox on a host the actor does not control) and re-vetted per row at
  send time (`attempt/2`: https, not internal, not a blocked server).

  A member with no Fediverse followers at all still reaches the person they
  answered, so the empty-follower case is not "nothing to do" any more.
  """
  def recipients(%User{} = user, %Post{} = post) do
    (delivery_inboxes(user) ++ answered_inbox(post)) |> Enum.uniq()
  end

  # Read off the struct, never re-queried: on the delete path the sidecar row has
  # already cascaded away with the post, and the preloaded association is the only
  # copy of the address left (see `Vutuv.Posts.delete_post/1`).
  defp answered_inbox(%Post{remote_reply_ref: %PostRemoteReply{inbox_uri: inbox}})
       when is_binary(inbox),
       do: [inbox]

  defp answered_inbox(%Post{}), do: []

  @doc """
  A member reposts another member's public post -> `Announce` to the reposter's
  Fediverse followers (issue #910). Enqueues only when all three hold: the
  reposter federates and has not moved out, the post is public, and the
  **original author** federates too (the `Announce` object is that author's Note
  id, which a non-federating author does not serve). Best effort like every
  other outbound activity.
  """
  def federate_repost(%Post{} = post, %User{} = reposter),
    do: maybe_federate_repost(post, reposter, &Docs.announce_activity/3)

  @doc "The member un-reposts -> `Undo(Announce)` with the matching id."
  def federate_unrepost(%Post{} = post, %User{} = reposter),
    do: maybe_federate_repost(post, reposter, &Docs.undo_announce_activity/3)

  defp maybe_federate_repost(%Post{} = post, %User{} = reposter, builder) do
    with true <- enabled?(),
         true <- federated?(reposter),
         false <- moved?(reposter),
         false <- Posts.restricted?(post),
         %User{} = author <- Repo.get(User, post.user_id),
         true <- federated?(author),
         [_ | _] = inboxes <- delivery_inboxes(reposter) do
      enqueue(reposter, inboxes, builder.(post, author, reposter))
    else
      _ -> :skip
    end
  end

  ## The pinned post as the `featured` collection (issue #1110)

  @doc """
  The member pinned a post -> `Add` it to their `featured` collection, so a
  remote profile shows the pin right away instead of at its next actor
  refresh. Only for a pin the anonymous public may see: the collection is
  served unauthenticated, so a restricted or frozen post never goes into it —
  and then nothing is sent either.
  """
  def federate_pin(%Post{} = post, %User{} = user) do
    # The public-visibility check sits behind the federation gates on purpose:
    # it costs a query, and for the overwhelming majority (members who do not
    # federate at all) there is nothing to decide.
    pin_activity(user, fn user ->
      if Posts.visible_to?(post, nil), do: Docs.add_featured_activity(post, user)
    end)
  end

  @doc """
  The pin was released or replaced -> `Remove` from the collection. Takes the
  bare post id: the post may be restricted, deleted or simply replaced by the
  time this runs, and a `Remove` naming an id the remote does not have pinned
  is a harmless no-op there. Sent whenever the member federates, so a post
  that stopped being public still leaves the remote profile.
  """
  def federate_unpin(post_id, %User{} = user) when is_binary(post_id),
    do: pin_activity(user, &Docs.remove_featured_activity(post_id, &1))

  # A builder returning nil means "nothing to send after all" (a pin the public
  # may not see), so it lands on the same :skip as every other closed gate.
  defp pin_activity(%User{} = user, builder) do
    with true <- enabled?(),
         true <- federated?(user),
         false <- moved?(user),
         [_ | _] = inboxes <- delivery_inboxes(user),
         activity when is_map(activity) <- builder.(user) do
      enqueue(user, inboxes, activity)
    else
      _ -> :skip
    end
  end

  @doc "Answers a Follow with Accept, straight to the follower's own inbox."
  def accept_follow(%User{} = user, follow_object, inbox_uri) do
    enqueue(user, [inbox_uri], Docs.accept_activity(user, follow_object))
  end

  # One document to many inboxes — the usual case, so it is encoded once.
  defp enqueue(user, inboxes, activity, opts \\ []) do
    json = Jason.encode!(activity)

    inboxes |> Enum.map(&{&1, json}) |> insert_deliveries(user, opts)
  end

  # A different document per inbox: withdrawing every follow a member holds is
  # N documents to N servers, and queued one at a time that is N inserts and N
  # nudges instead of one of each.
  defp enqueue_each(pairs, user) do
    pairs
    |> Enum.map(fn {inbox, activity} -> {inbox, Jason.encode!(activity)} end)
    |> insert_deliveries(user, [])
  end

  defp insert_deliveries([], _user, _opts), do: :ok

  defp insert_deliveries(pairs, user, opts) do
    stamp = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
    due = DateTime.add(DateTime.utc_now(:second), Keyword.get(opts, :delay_seconds, 0))
    rebuild_from = Keyword.get(opts, :rebuild_from)

    rows =
      Enum.map(pairs, fn {inbox, json} ->
        %{
          id: Vutuv.UUIDv7.generate(),
          user_id: user.id,
          inbox_uri: inbox,
          activity_json: json,
          rebuild_from: rebuild_from,
          attempts: 0,
          next_attempt_at: due,
          inserted_at: stamp,
          updated_at: stamp
        }
      end)

    Repo.insert_all(Delivery, rows)
    Deliverer.nudge()
    :ok
  end

  ## Account deletion broadcast (issue #985)

  @doc """
  Prepares the actor `Delete` broadcast for a member about to be deleted: reads
  the follower inboxes and the signing key **now**, while they still exist, and
  returns a self-contained payload for `send_actor_delete/1` to POST **after**
  the account (and its actor/follower rows) are gone. Returns `nil` for a
  member who never federated — no actor, no followers, nothing to send.

  Capturing then sending is the whole trick: the delivery queue keys on
  `user_id`, so a queued row would cascade away with the member; holding the
  key and inboxes in memory lets the signed POST outlive them.

  Gated on `ever_federated?/1` (issue #1102). It used to require `federated?/1`,
  which is false for a frozen, suspended or deactivated account — so deleting
  exactly the accounts moderation had already hidden broadcast nothing, and their
  posts stayed up everywhere.
  """
  def prepare_actor_delete(%User{} = user) do
    with true <- enabled?(),
         true <- ever_federated?(user),
         %Actor{} = actor <- get_actor(user),
         [_ | _] = inboxes <- actor_delete_inboxes(user) do
      %{
        key_id: Docs.key_id(user),
        private_key_pem: actor.private_key_pem,
        inboxes: inboxes,
        activity_json: Jason.encode!(Docs.actor_delete_activity(user))
      }
    else
      _ -> nil
    end
  end

  @doc """
  Sends a prepared actor `Delete` (from `prepare_actor_delete/1`) to every
  follower inbox, signed with the captured key. Best effort and self-contained,
  so it runs after the account is gone: a `nil` payload (a member who never
  federated) is a no-op, and a failed or timed-out POST never surfaces —
  account deletion must succeed regardless of the Fediverse side. Remote
  deletion is advisory by protocol, so this is a courtesy, never a guarantee.
  """
  def send_actor_delete(nil), do: :ok

  def send_actor_delete(%{inboxes: inboxes} = payload) do
    if enabled?() do
      inboxes
      |> Task.async_stream(&post_actor_delete(payload, &1),
        max_concurrency: 5,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Stream.run()
    end

    :ok
  end

  defp post_actor_delete(payload, inbox_uri) do
    with %URI{scheme: "https", host: host} <- URI.parse(inbox_uri),
         false <- Vutuv.Ssrf.resolves_to_internal?(host) do
      ap_post(inbox_uri, payload.activity_json, payload.key_id, payload.private_key_pem)
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  ## Outbound deliveries (drained by Vutuv.Fediverse.Deliverer)

  @doc "Sends every due delivery (called by the Deliverer; returns how many)."
  def deliver_due do
    if enabled?(), do: do_deliver_due(), else: 0
  end

  # Never drain the queue while the installation-wide switch is off (the
  # Deliverer child can still be running): an air-gapped / disabled install must
  # make no outbound POSTs, even for deliveries queued before it was turned off.
  defp do_deliver_due do
    now = DateTime.utc_now(:second)

    due =
      Repo.all(
        from(d in Delivery,
          where: d.attempts < @max_attempts and d.next_attempt_at <= ^now,
          limit: 100,
          preload: [:user]
        )
      )

    # Load each user's actor once — a burst of deliveries for one member all
    # share the same actor row — instead of re-querying it per delivery.
    actors = actors_by_user_id(due)

    due
    |> Task.async_stream(&attempt(&1, actors[&1.user_id]),
      max_concurrency: 5,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Stream.run()

    length(due)
  end

  # The signing actor for each member behind a list of rows carrying `user_id`
  # (deliveries, follower re-checks), in one query instead of one per row.
  defp actors_by_user_id(rows) do
    user_ids = rows |> Enum.map(& &1.user_id) |> Enum.uniq()

    from(a in Actor, where: a.user_id in ^user_ids)
    |> Repo.all()
    |> Map.new(&{&1.user_id, &1})
  end

  defp attempt(%Delivery{user: %User{} = user} = delivery, actor) do
    with %Actor{} = actor <- actor,
         %URI{scheme: "https", host: host} <- URI.parse(delivery.inbox_uri),
         false <- Vutuv.Ssrf.resolves_to_internal?(host),
         # A server the operator blocked while this row waited in the queue must
         # not be delivered to either — a block is both ears and mouth shut.
         false <- instance_blocked?(delivery.inbox_uri),
         {:ok, delivery} <- rebuilt(delivery, user) do
      post_activity(delivery, user, actor)
    else
      # No key, a non-https inbox, an internal target, a blocked server, or a
      # post that is gone or no longer public: undeliverable for good, so the row
      # goes instead of clogging the queue.
      _ -> Repo.delete(delivery)
    end
  end

  defp attempt(%Delivery{} = delivery, _actor), do: Repo.delete(delivery)

  # A held row re-renders its activity now, so a picture the AI scan released
  # while it waited rides along (issue #1070). The gates are re-checked at the
  # same time: the post may have been deleted or had its audience closed during
  # the hold, and then this delivery must not go out at all.
  defp rebuilt(%Delivery{rebuild_from: nil} = delivery, _user), do: {:ok, delivery}

  defp rebuilt(%Delivery{rebuild_from: marker} = delivery, user) do
    with [kind, post_id] <- String.split(marker, ":", parts: 2),
         builder when is_function(builder) <- rebuild_builder(kind),
         %Post{} = post <- Posts.get_post(post_id),
         false <- Posts.restricted?(post) do
      post = Repo.preload(post, Docs.note_preloads())
      {:ok, %{delivery | activity_json: Jason.encode!(builder.(post, user))}}
    else
      _ -> :drop
    end
  end

  defp rebuild_builder("post_create"), do: &Docs.create_activity/2
  defp rebuild_builder("post_update"), do: &Docs.update_activity/2
  defp rebuild_builder(_kind), do: nil

  defp post_activity(delivery, user, actor) do
    case ap_post(
           delivery.inbox_uri,
           delivery.activity_json,
           Docs.key_id(user),
           actor.private_key_pem
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        Repo.delete(delivery)

      # The inbox is gone for good — no point retrying.
      {:ok, %Req.Response{status: status}} when status in [404, 410] ->
        Repo.delete(delivery)

      {:ok, %Req.Response{status: status}} ->
        fail(delivery, "HTTP #{status}")

      {:error, exception} ->
        fail(delivery, Exception.message(exception))
    end
  end

  # One signed POST of an activity JSON to an inbox — the shared transport for
  # both the queued deliveries and the synchronous account-Delete broadcast.
  defp ap_post(inbox_uri, body, key_id, private_key_pem) do
    headers =
      HttpSignature.signed_headers("post", inbox_uri, body, key_id, private_key_pem) ++
        [{"content-type", "application/activity+json"}, {"user-agent", Http.user_agent()}]

    options =
      Keyword.merge(
        [
          url: inbox_uri,
          body: body,
          headers: headers,
          receive_timeout: 10_000,
          connect_options: [timeout: 2_000],
          retry: false,
          redirect: false
        ],
        Application.get_env(:vutuv, :fediverse_req_options, [])
      )

    Req.post(options)
  end

  defp fail(%Delivery{attempts: attempts} = delivery, error) when attempts + 1 >= @max_attempts do
    Logger.info("fediverse delivery to #{delivery.inbox_uri} gave up: #{error}")
    record_give_up(delivery, error)
    Repo.delete(delivery)
  end

  defp fail(%Delivery{attempts: attempts} = delivery, error) do
    delivery
    |> Ecto.Changeset.change(
      attempts: attempts + 1,
      next_attempt_at: backoff_at(attempts + 1),
      last_error: String.slice(error, 0, 255)
    )
    |> Repo.update()
  end

  # 2, 4, 8 ... minutes — the webhook ladder; attempt 8 sits about 4h out.
  defp backoff_at(attempts) do
    DateTime.add(DateTime.utc_now(:second), trunc(:math.pow(2, attempts)) * 60)
  end

  # The activities whose give-up an operator has to be able to see (issue #1102).
  # A `Create` that never lands means one post did not travel; a `Delete` that
  # never lands means a copy we promised to have asked about is still published,
  # and a `Flag` that never lands means a report nobody received. Recording every
  # type instead would drown that signal in ordinary delivery noise.
  @revocation_types ~w(Delete Flag)

  defp record_give_up(%Delivery{} = delivery, error) do
    with {:ok, %{"type" => type} = activity} when type in @revocation_types <-
           Jason.decode(delivery.activity_json) do
      Repo.insert(%DeliveryFailure{
        activity_type: type,
        host: BlockedInstance.normalize_host(delivery.inbox_uri) || "unknown",
        object_uri: give_up_object(activity),
        user_id: delivery.user_id,
        attempts: @max_attempts,
        last_error: String.slice(error, 0, 255)
      })
    end

    :ok
  end

  # What the activity was about: a Tombstone/actor object, a bare id, or the
  # first entry of a Flag's object list.
  defp give_up_object(%{"object" => %{"id" => id}}) when is_binary(id), do: id
  defp give_up_object(%{"object" => id}) when is_binary(id), do: id
  defp give_up_object(%{"object" => [id | _]}) when is_binary(id), do: id
  defp give_up_object(_activity), do: nil

  ## Remote actors

  @doc """
  Fetches a remote actor document (by its id or a keyId — the fragment is
  stripped): https only, SSRF-guarded, size-capped. Returns the delivery
  coordinates and the key deliveries from that actor are verified against.
  """
  def fetch_remote_actor(uri, signer \\ nil) do
    bare = uri |> URI.parse() |> struct!(fragment: nil) |> URI.to_string()

    with {:parse, %URI{scheme: "https", host: host}} <- {:parse, URI.parse(bare)},
         {:ssrf, false} <- {:ssrf, Vutuv.Ssrf.resolves_to_internal?(host)},
         {:ok, %Req.Response{status: 200, body: body}} <- ap_get(bare, signer),
         {:size, true} <- {:size, byte_size(body) <= @max_body_bytes},
         {:ok, %{"id" => id, "inbox" => inbox} = doc} <- Jason.decode(body) do
      {:ok,
       %{
         id: id,
         inbox: inbox,
         shared_inbox: get_in(doc, ["endpoints", "sharedInbox"]),
         # Cosmetic, remote-supplied and hostile: cap before it reaches the
         # follower row so the display fields can never overflow their column.
         preferred_username: truncate(doc["preferredUsername"]),
         name: truncate(doc["name"]),
         # The account's own description (issue #1160). Kept raw here — the
         # caller reduces it to text before it is stored, like every other
         # stranger's HTML.
         summary: doc["summary"],
         # The account's picture, when the document names one (issue #1163).
         # Only the URL travels here; whether it is fetched, stored and shown is
         # decided later and behind the AI gate.
         icon: Media.actor_icon_url(doc),
         public_key_id: get_in(doc, ["publicKey", "id"]),
         public_key_pem: get_in(doc, ["publicKey", "publicKeyPem"]),
         # The aliases the remote account claims (issue #986): a Move *to* this
         # account is only honored once it lists the origin here, so move_out/2
         # checks our own actor URL is among them. AP allows a bare string or a
         # list; normalize to a list of strings.
         also_known_as: normalize_uri_list(doc["alsoKnownAs"])
       }}
    else
      {:parse, _} -> {:error, :https_only}
      {:ssrf, true} -> {:error, :internal_host}
      {:size, false} -> {:error, :too_large}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, _} = error -> error
      other -> {:error, {:bad_actor, other}}
    end
  end

  # A remote actor's display strings are cosmetic and untrusted; keep only a
  # column's worth (nil and non-strings pass through as nil).
  defp truncate(value) when is_binary(value), do: String.slice(value, 0, 255)
  defp truncate(_), do: nil

  # `alsoKnownAs` is a single URI string or a list of them; anything else (or
  # absent) is no aliases. Keep only the strings.
  defp normalize_uri_list(value) when is_binary(value), do: [value]
  defp normalize_uri_list(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp normalize_uri_list(_), do: []

  defp ap_get(url, signer) do
    signature_headers =
      case signer do
        {key_id, private_key_pem} ->
          HttpSignature.signed_headers("get", url, nil, key_id, private_key_pem)

        nil ->
          []
      end

    options =
      Keyword.merge(
        [
          url: url,
          headers:
            signature_headers ++
              [{"accept", "application/activity+json"}, {"user-agent", Http.user_agent()}],
          receive_timeout: 8_000,
          connect_options: [timeout: 2_000],
          retry: false,
          redirect: false,
          # Stream with a hard ceiling: fetch_remote_actor runs synchronously in
          # the inbox web request against an attacker-controlled host BEFORE the
          # signature check, so a multi-GB body must be dropped during receipt,
          # not buffered whole and size-checked after.
          into: Vutuv.Http.capped_collector(@max_body_bytes)
        ],
        Application.get_env(:vutuv, :fediverse_req_options, [])
      )

    Req.get(options)
  end
end
