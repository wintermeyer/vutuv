defmodule Vutuv.Fediverse do
  @moduledoc """
  Follow-only ActivityPub federation (outbound).

  People on Mastodon and other Fediverse servers can follow a member who
  opted in (`users.fediverse_followers?`, the Fediverse settings page) and
  receive their **public** posts; nothing federates inbound — no remote
  posts, likes or replies are stored, only who follows whom and where to
  deliver. The moving parts:

    * actors — the member's RSA keypair (`Vutuv.Fediverse.Actor`), created
      lazily on opt-in; `VutuvWeb.Fediverse.Docs` renders the documents.
    * followers — remote actors following a member
      (`Vutuv.Fediverse.Follower`), written by the inbox on Follow/Undo and
      kept in step with the remote's own Update/Delete; the ones who leave
      without saying so are found by the slow re-check
      (`Vutuv.Fediverse.FollowerPruner`).
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

  import Ecto.Query
  import Vutuv.Moderation.Query, only: [account_hidden_row: 1]

  require Logger

  alias Vutuv.Accounts.User
  alias Vutuv.Activity
  alias Vutuv.Fediverse.Actor
  alias Vutuv.Fediverse.BlockedInstance
  alias Vutuv.Fediverse.Deliverer
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.DeliveryFailure
  alias Vutuv.Fediverse.Follower
  alias Vutuv.Fediverse.FollowerPrune
  alias Vutuv.Fediverse.HttpSignature
  alias Vutuv.Fediverse.Keys
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.NoteEvent
  alias Vutuv.Fediverse.PostDelivery
  alias Vutuv.Fediverse.Reaction
  alias Vutuv.Pages
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostDenial
  alias Vutuv.Posts.PostRemoteReply
  alias Vutuv.RateLimiter
  alias Vutuv.RemoteHtml
  alias Vutuv.Repo
  alias Vutuv.SearchText
  alias Vutuv.SocialFeed.Http
  alias Vutuv.UUIDv7
  alias VutuvWeb.Fediverse.Docs

  @max_attempts 8
  @max_body_bytes 500_000

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
  # table (`VutuvWeb.FediverseFollowersLive`) built on the three functions
  # below. Everything is scoped to the member's own rows first, so the work is
  # bounded by their following, not by the installation's.
  @followers_per_page 50

  # The sortable columns, by the `?sort=` value a header button sets. None of
  # them is a plain column: "account" sorts by what the row actually shows
  # (display name, else handle, else the actor URI), "server" by the host
  # inside the actor URI.
  @follower_sort_columns ~w(account server followed)

  # How many servers the filter dropdown offers. Beyond that the free-text
  # search is the way in - a select with 400 entries is not a filter.
  @follower_host_choices 30

  @doc "The follower-browser page size, shared by the query and the pager."
  def followers_per_page, do: @followers_per_page

  @doc "The sortable follower-browser columns (the `?sort=` values)."
  def follower_sort_columns, do: @follower_sort_columns

  @doc """
  Normalizes raw request params into a validated filter map for the follower
  browser: `q` (free-text search, trimmed), `server` (an exact host, lowercased),
  `sort` (a known column, default "followed") and `dir` ("asc"/"desc", default
  per column - newest first for the date, A-Z for the text columns). Anything
  invalid falls back to a safe default, so the params can never reach the query.
  """
  def follower_filters(params) when is_map(params) do
    sort = validated_follower_sort(params["sort"])

    %{
      q: Pages.blank_to_nil(params["q"]),
      server: params["server"] |> Pages.blank_to_nil() |> normalize_follower_server(),
      sort: sort,
      dir: validated_follower_dir(params["dir"]) || follower_default_dir(sort)
    }
  end

  @doc """
  The direction a column sorts in when it is picked for the first time: the
  date newest-first (what a follower list is read for), the text columns A-Z.
  """
  def follower_default_dir("followed"), do: "desc"
  def follower_default_dir(_text_column), do: "asc"

  @doc "How many of the member's remote followers match `filters` (for the pager)."
  def count_followers(%User{id: user_id}, filters \\ %{}) do
    user_id |> followers_base(filters) |> Repo.aggregate(:count)
  end

  @doc """
  One page of the member's follower browser: filtered, searched, sorted and
  paginated. `opts` may carry `:total` (skip the recount) and `:per_page`
  (default `followers_per_page/0`).
  """
  def list_followers_page(%User{id: user_id}, filters, params \\ %{}, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, @followers_per_page)
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
  def follower_hosts(%User{id: user_id}, limit \\ @follower_host_choices) do
    Repo.all(
      from(f in Follower,
        where: f.user_id == ^user_id,
        group_by: uri_host(f.actor_uri),
        order_by: [desc: count(f.id), asc: uri_host(f.actor_uri)],
        limit: ^limit,
        select: %{host: uri_host(f.actor_uri), followers: count(f.id)}
      )
    )
  end

  defp validated_follower_sort(sort) when sort in @follower_sort_columns, do: sort
  defp validated_follower_sort(_other), do: "followed"

  defp validated_follower_dir(dir) when dir in ~w(asc desc), do: dir
  defp validated_follower_dir(_other), do: nil

  defp normalize_follower_server(nil), do: nil
  defp normalize_follower_server(host), do: String.downcase(host)

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
    # A pasted "@user@host" is two facts, not one substring - matched against
    # the handle and the actor URI separately, so the full handle a member
    # copies out of a Mastodon profile finds the row it names.
    case term |> String.trim_leading("@") |> String.split("@", parts: 2) do
      [name, host] when host != "" ->
        where(
          query,
          [f],
          ilike(f.handle, ^contains(name)) and ilike(f.actor_uri, ^contains(host))
        )

      _one_part ->
        like = contains(term)

        where(
          query,
          [f],
          ilike(f.name, ^like) or ilike(f.handle, ^like) or ilike(f.actor_uri, ^like)
        )
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
      failed_takedowns: delivery_failure_count()
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
  @inbound_window_ms :timer.hours(1)

  # Answers a member may send out to other networks per hour (issue #1070). Set
  # for a person holding a conversation, not for a script: a real exchange is a
  # handful of messages, so this only ever bites automation.
  @outbound_reply_limit 30

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
  Deletes everything stored from `host`: its remote followers, the replies its
  members wrote under vutuv posts, the outbound deliveries still queued for it and
  the records of what was delivered there.
  Returns `%{followers: n, notes: n, deliveries: n, post_deliveries: n}`.
  """
  def purge_instance(host) when is_binary(host) do
    {followers, _} =
      Repo.delete_all(from(f in Follower, where: uri_host(f.actor_uri) == ^host))

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
      notes: notes,
      deliveries: deliveries,
      post_deliveries: post_deliveries
    }
  end

  @doc """
  What each remote server has stored here, biggest first — the operator's "who
  is sending us the most" list on `/admin/fediverse`, and what a block decision
  is made from. Capped at `limit` hosts.
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
      names no local member at all: it is broadcast to everyone following that
      actor, so the addressees are exactly the members it follows here. This is
      the case the endpoint is worth having for — one account deletion used to
      mean one signed delivery per member.
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

    (audience_uris(activity) ++
       audience_uris(object) ++
       [activity["object"], object["object"], object["inReplyTo"]])
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

  defp lifecycle_users(%{"type" => type} = activity, actor_uri)
       when type in ~w(Update Delete) and is_binary(actor_uri) do
    case activity_object_id(activity["object"]) do
      ^actor_uri -> followed_local_users(actor_uri)
      uri when is_binary(uri) -> note_holding_users(actor_uri, uri)
      _ -> []
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
    from(n in Note,
      join: p in Post,
      on: p.id == n.post_id,
      where: n.post_id in ^post_ids,
      where: n.audience == "public" or p.user_id == ^note_viewer_id(viewer),
      order_by: [asc: n.received_at, asc: n.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.post_id)
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
  def get_note(id), do: UUIDv7.with_cast(id, &Repo.get(Note, &1))

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
  def expire_due_notes(now \\ nil) do
    now = now || DateTime.utc_now(:second)
    {count, _} = Repo.delete_all(from(n in Note, where: n.expires_at <= ^now))
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
      Enum.any?(addressed, &String.ends_with?(&1, "/followers")) -> "followers"
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
    Repo.insert!(%NoteEvent{
      action: action,
      host: Note.host(note.actor_uri) || "unknown",
      actor_digest: note_actor_digest(note.actor_uri),
      audience: note.audience,
      user_id: author_id,
      actor_id: actor.id
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
         [_ | _] = inboxes <- delivery_inboxes(user) do
      enqueue(user, inboxes, Docs.actor_delete_activity(user))
    else
      _ -> :skip
    end
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

  defp enqueue(user, inboxes, activity, opts \\ []) do
    json = Jason.encode!(activity)
    now = DateTime.utc_now(:second)
    stamp = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
    due = DateTime.add(now, Keyword.get(opts, :delay_seconds, 0))

    rows =
      Enum.map(inboxes, fn inbox ->
        %{
          id: Vutuv.UUIDv7.generate(),
          user_id: user.id,
          inbox_uri: inbox,
          activity_json: json,
          rebuild_from: Keyword.get(opts, :rebuild_from),
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
         [_ | _] = inboxes <- delivery_inboxes(user) do
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
