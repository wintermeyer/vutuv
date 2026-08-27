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
  import Vutuv.Identity.Query, only: [party_is: 2]
  import Vutuv.Moderation.Query, only: [account_confirmed_row: 1, account_hidden_row: 1]

  require Logger

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Activity
  alias Vutuv.Engagement
  alias Vutuv.Fediverse.Actor
  alias Vutuv.Fediverse.BlockedInstance
  alias Vutuv.Fediverse.Bookmark
  alias Vutuv.Fediverse.Deliverer
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.DeliveryFailure
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.Follower
  alias Vutuv.Fediverse.FollowerPrune
  alias Vutuv.Fediverse.Hashtags
  alias Vutuv.Fediverse.HttpSignature
  alias Vutuv.Fediverse.Keys
  alias Vutuv.Fediverse.Media
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.NoteEvent
  alias Vutuv.Fediverse.NoteLike
  alias Vutuv.Fediverse.NoteRepost
  alias Vutuv.Fediverse.PostBoost
  alias Vutuv.Fediverse.PostDelivery
  alias Vutuv.Fediverse.PostLike
  alias Vutuv.Fediverse.PostLookup
  alias Vutuv.Fediverse.PostRepost
  alias Vutuv.Fediverse.Reaction
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteFollow
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Handles
  alias Vutuv.Keyset
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Pages
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostDenial
  alias Vutuv.Posts.PostRemoteReply
  alias Vutuv.Posts.Screenshots
  alias Vutuv.RateLimiter
  alias Vutuv.RemoteHtml
  alias Vutuv.RemoteMedia
  alias Vutuv.Repo
  alias Vutuv.SearchText
  alias Vutuv.Social
  alias Vutuv.SocialFeed.Http
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
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

  # One topic for every picture leaving the AI gate; see `remote_images_topic/0`.
  @remote_images_topic "fediverse:remote_images"

  @doc "The installation-wide switch (FEDIVERSE_ENABLED; off = no endpoints, no deliveries)."
  def enabled?, do: Application.get_env(:vutuv, :fediverse_enabled, true)

  @doc """
  Whether this member or **page** takes part.

  For a member: the global switch, their opt-in, a confirmed address and an
  account in good standing (a frozen, suspended or deactivated profile is hidden
  on vutuv, so it must not keep federating).

  For a page (issue #1334): the global switch, its opt-in, a **claimed handle**,
  and `Organizations.public_visible?/1` — active **and** not frozen.

  Two of those are easy to get wrong. `status` stays "active" through a freeze,
  so a gate reading only it would keep answering for a page vutuv is hiding, on
  a network where nobody can see why. And the handle is not decoration: it is
  the page's address out there — WebFinger's `subject` and the actor document's
  `preferredUsername` are both built from it — so a page that never claimed one
  cannot be federated, only unreachable.

  For a **topic** (issue #1330): the global switch, and the tag being a topic of
  its own rather than another name for one (#1338) — an alias must never become
  a second address for the same posts. Deliberately no per-tag opt-in: a tag is
  not somebody's account, and nobody's content is published by its existence,
  because what a tag actor announces is filtered by each author's own
  `users.fediverse_followers?` at announce time.
  """
  def federated?(%User{} = user) do
    enabled?() and user.fediverse_followers? and user.email_confirmed? and
      is_nil(user.frozen_at) and is_nil(user.deactivated_at) and not suspended?(user)
  end

  def federated?(%Organization{} = organization) do
    enabled?() and organization.fediverse_followers? and
      is_binary(organization.username) and
      Organizations.public_visible?(organization)
  end

  def federated?(%Tag{merged_into_id: id}) when is_binary(id), do: false
  def federated?(%Tag{}), do: enabled?()

  defp suspended?(%User{suspended_until: nil}), do: false

  defp suspended?(%User{suspended_until: until}),
    do: NaiveDateTime.compare(until, NaiveDateTime.utc_now()) == :gt

  @doc """
  Whether this member's own standing lets an outbound act leave the building at
  all: `:ok`, or the same `{:error, reason}` the gates below would answer with.

  It is the **viewer-level** half of every outbound gate in this module
  (`check_remote_post_act/2`, `check_note_like/2` and their siblings), asked on
  its own so a control can know the answer *before* it is pressed. That is what
  lets the action bar on a card from another network paint a press on the spot
  the way the vutuv bar does: for a member who does not take part in the
  Fediverse — which is most of them, since it is opt-in while remote posts reach
  their feed anyway — a heart that fills and then empties again on every single
  press is worse than the explanation they get today, so that bar keeps waiting
  and this predicate is what tells the two apart.

  Free of queries: a config read and three struct reads on the loaded viewer.
  The gates' remaining questions are about the *subject* (`instance_blocked?`,
  readability) and are already true of anything on screen, and the hourly budget
  is claimed at press time by design — so `:ok` here means "this press will
  succeed" for everything but a member 200 likes into one hour or a post deleted
  in the last few seconds. Those two are what the refusal counter in the bars is
  for: it changes the button's DOM id, which is the only way to overrule an
  optimistic paint (LiveView's JS-command stash lives on the element and never
  expires).

  `test/vutuv/fediverse/outbound_standing_test.exs` holds it against the real
  gate for each state, since two copies of one cond is exactly the drift that
  would make a bar promise what the gate then refuses.
  """
  def outbound_standing(%User{} = user) do
    cond do
      not enabled?() -> {:error, :fediverse_disabled}
      not federated?(user) -> {:error, :not_federating}
      moved?(user) -> {:error, :moved}
      true -> :ok
    end
  end

  def outbound_standing(_no_viewer), do: {:error, :not_signed_in}

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

  # The page twin (issue #1334): it holds a keypair, whatever its switch says
  # now. Turning the switch off does not unsend what other servers already have,
  # so anything that still has to reach them keys on this, not on `federated?/1`.
  def ever_federated?(%Organization{} = organization),
    do: enabled?() and get_actor(organization) != nil

  ## Actors

  @doc """
  The member's or page's actor (keypair), created on first use. Race-safe;
  one function with a head per kind (issue #1416), because the keypair is the
  same thing and only its owner column differs.

  A page's keypair can exist before anything is federated — it is invisible
  outside this database. The parts other servers see (WebFinger, the actor
  document, delivery, an inbox that answers Follow) have to arrive together,
  because being findable without a working inbox means somebody presses Follow
  and nothing ever happens.
  """
  def ensure_actor(subject) do
    case get_actor(subject) do
      nil ->
        {private_pem, public_pem} = Keys.generate()

        subject
        |> new_actor(private_pem, public_pem)
        |> Repo.insert(on_conflict: :nothing, conflict_target: actor_conflict_target(subject))

        {:ok, get_actor(subject)}

      actor ->
        {:ok, actor}
    end
  end

  defp new_actor(%User{id: id}, private_pem, public_pem),
    do: %Actor{user_id: id, private_key_pem: private_pem, public_key_pem: public_pem}

  defp new_actor(%Organization{id: id}, private_pem, public_pem),
    do: %Actor{organization_id: id, private_key_pem: private_pem, public_key_pem: public_pem}

  defp actor_conflict_target(%User{}), do: [:user_id]
  defp actor_conflict_target(%Organization{}), do: [:organization_id]

  @doc "The member's or page's actor, or nil."
  def get_actor(%User{id: user_id}), do: Repo.get_by(Actor, user_id: user_id)
  def get_actor(%Organization{id: id}), do: Repo.get_by(Actor, organization_id: id)

  @doc """
  The keypair a **tag** signs with, minted on first use (issue #1330).

  A topic becomes an actor anyone on any server can follow without an account
  here, and its actor name is the tag's slug with no mapping in between — which
  is why this waited for the slug grammar to be settled (#1337/#1332): renaming
  an actor other servers already follow costs a `Move` per tag.

  Like the page's, the keypair can exist before anything is federated: it is
  invisible outside this database. What a remote server sees — WebFinger on the
  tag host, the `Group` document, the inbox that answers `Follow`, the
  `Announce` of a tagged post — has to arrive together, because a Follow nobody
  answers stays pending forever on the other side.

  Only a **canonical** tag gets one. An alias is another name for a topic
  (#1338), not a topic, so it must never become a second address for the same
  posts.
  """
  def ensure_tag_actor(%Tag{merged_into_id: id}) when is_binary(id), do: {:error, :alias}

  def ensure_tag_actor(%Tag{} = tag) do
    case get_tag_actor(tag) do
      nil ->
        {private_pem, public_pem} = Keys.generate()

        %Actor{
          tag_id: tag.id,
          private_key_pem: private_pem,
          public_key_pem: public_pem
        }
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:tag_id])

        {:ok, get_tag_actor(tag)}

      actor ->
        {:ok, actor}
    end
  end

  @doc "The tag's actor, or nil."
  def get_tag_actor(%Tag{id: id}), do: Repo.get_by(Actor, tag_id: id)

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
    with :ok <- check_inbound_cap(attrs[:actor_uri] || attrs["actor_uri"]),
         {:ok, follower} <-
           %Follower{user_id: user.id}
           |> Follower.changeset(attrs)
           |> Repo.insert(
             on_conflict:
               {:replace, [:inbox_uri, :shared_inbox_uri, :handle, :name, :updated_at]},
             conflict_target: [:user_id, :actor_uri],
             # Without this a repeat Follow hands back the id Ecto minted for
             # the INSERT that lost the conflict — an id no row ever had. The
             # stored row is correct either way, so it stayed invisible; it
             # would stop being invisible the first time a caller used the id.
             returning: true
           ) do
      broadcast_remote_followers_changed([user.id])
      {:ok, follower}
    end
  end

  @doc """
  The page twin of `add_follower/2` (issue #1334): records a remote follower of
  an organization page, idempotent per remote actor.

  Its own function rather than a widened `add_follower/2` because the upsert
  target differs — `[:organization_id, :actor_uri]` against
  `[:user_id, :actor_uri]` — and that target is what makes a repeat Follow a
  re-sync instead of a duplicate. A repeat Follow from the same server is the
  normal case, not the exception.
  """
  def add_organization_follower(%Organization{} = organization, attrs) do
    with :ok <- check_inbound_cap(attrs[:actor_uri] || attrs["actor_uri"]) do
      %Follower{organization_id: organization.id}
      |> Follower.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:inbox_uri, :shared_inbox_uri, :handle, :name, :updated_at]},
        conflict_target: [:organization_id, :actor_uri],
        returning: true
      )
    end
  end

  @doc """
  Who a follower row (or a prune row) is about: the member, the page (issue
  #1334) or the topic (issue #1330) being followed. Exactly one of the three is
  set — the database CHECK says so — which is what makes the `||` chain total.

  The one definition of "whose follower is this", so a surface that renders such
  a row does not have to remember the third owner kind for itself.

  Needs the associations preloaded, and says so rather than guessing: an
  unloaded association is truthy, so a plain `||` chain would hand back
  `%Ecto.Association.NotLoaded{}` and the caller would quietly treat it as an
  owner it cannot use — which is how the pruner came to sign nothing at all for
  a page's followers. A forgotten preload is a bug in the query, so it raises
  here instead of degrading somewhere further along.
  """
  def followed(%{user: user, organization: organization, tag: tag}) do
    [user, organization, tag]
    |> Enum.reject(&(&1 == nil))
    |> case do
      [%Ecto.Association.NotLoaded{} | _] ->
        raise ArgumentError, "Fediverse.followed/1 needs :user, :organization and :tag preloaded"

      [owner | _] ->
        owner

      [] ->
        nil
    end
  end

  @doc "Drops a page's remote follower (the inbox's Undo). Idempotent."
  def remove_organization_follower(%Organization{id: id}, actor_uri) do
    {count, _} =
      Repo.delete_all(
        from(f in Follower, where: f.organization_id == ^id and f.actor_uri == ^actor_uri)
      )

    count
  end

  @doc """
  Records a remote follower of a **topic** (issue #1330), idempotently: a server
  that re-delivers its `Follow` refreshes the row it already has rather than
  adding a second.
  """
  def add_tag_follower(%Tag{} = tag, attrs) do
    with :ok <- check_inbound_cap(attrs[:actor_uri] || attrs["actor_uri"]) do
      %Follower{tag_id: tag.id}
      |> Follower.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:inbox_uri, :shared_inbox_uri, :handle, :name, :updated_at]},
        conflict_target: [:tag_id, :actor_uri],
        returning: true
      )
    end
  end

  @doc "Drops a topic's remote follower (the inbox's Undo). Idempotent."
  def remove_tag_follower(%Tag{id: id}, actor_uri) do
    {count, _} =
      Repo.delete_all(from(f in Follower, where: f.tag_id == ^id and f.actor_uri == ^actor_uri))

    count
  end

  @doc "How many remote accounts follow this topic."
  def tag_remote_follower_count(%Tag{id: id}),
    do: Repo.aggregate(from(f in Follower, where: f.tag_id == ^id), :count)

  @doc "The inboxes a topic's activities go to, one per remote follower."
  def tag_follower_inboxes(%Tag{id: id}) do
    from(f in Follower,
      where: f.tag_id == ^id,
      select: coalesce(f.shared_inbox_uri, f.inbox_uri),
      distinct: true
    )
    |> Repo.all()
  end

  @doc "A page's remote followers, newest first."
  def list_organization_followers(%Organization{id: id}, limit \\ 50) do
    Repo.all(
      from(f in Follower,
        where: f.organization_id == ^id,
        order_by: [desc: f.inserted_at, desc: f.id],
        limit: ^limit
      )
    )
  end

  @doc """
  Re-syncs an existing follower row from the remote actor document (the
  inbox's `Update` handler). A no-op when that actor follows nobody here: an
  `Update` is a broadcast, not a follow request, so it must never mint a row.
  Like `add_follower/2` it swallows a rejected changeset — a hostile actor
  document must not crash the inbox.
  """
  def refresh_follower(%User{id: user_id}, %{actor_uri: actor_uri} = attrs) do
    with %Follower{} = follower <- Repo.get_by(Follower, user_id: user_id, actor_uri: actor_uri),
         {:ok, _updated} <- follower |> Follower.changeset(attrs) |> Repo.update() do
      # The name and handle are what the follower table shows, so a rename is a
      # change to that page even though no row came or went.
      broadcast_remote_followers_changed([user_id])
    end

    :ok
  end

  def remove_follower(%User{id: user_id}, actor_uri) do
    {count, _} =
      Repo.delete_all(
        from(f in Follower, where: f.user_id == ^user_id and f.actor_uri == ^actor_uri)
      )

    # Only when a row really went: an `Undo` for a follow we never stored is
    # ordinary inbox traffic, and waking every open page for it would be noise.
    if count > 0, do: broadcast_remote_followers_changed([user_id])

    :ok
  end

  @doc "How many remote accounts follow this member or page."
  def follower_count(%User{id: user_id}) do
    Repo.aggregate(from(f in Follower, where: f.user_id == ^user_id), :count)
  end

  def follower_count(%Organization{id: id}) do
    Repo.aggregate(from(f in Follower, where: f.organization_id == ^id), :count)
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

  The **page** clause (issue #1334) reads the same three things off the page,
  and it is not decoration: pages and members share one handle namespace, so
  WebFinger resolves `acct:<handle>@<host>` to either kind and hands whatever it
  found to the refusal path. Without this clause that path raised
  `FunctionClauseError` — a **500** — for every page that had claimed a handle
  and not switched federation on, which is the state every page starts in.
  Production answered exactly that for `acct:vutuv@vutuv.de`.
  """
  def departed?(%User{} = user) do
    enabled?() and not user.fediverse_followers? and get_actor(user) != nil
  end

  def departed?(%Organization{} = organization) do
    enabled?() and not organization.fediverse_followers? and
      get_actor(organization) != nil
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

  @doc """
  How many of `owner`'s remote followers match `filters` (for the pager).
  `owner` is a member or a page (issue #1334).
  """
  def count_followers(owner, filters \\ %{}) do
    owner |> followers_base(filters) |> Repo.aggregate(:count)
  end

  @doc """
  One page of `owner`'s follower browser: filtered, searched, sorted and
  paginated. `opts` may carry `:total` (skip the recount) and `:per_page`
  (default `browse_per_page/0`).
  """
  def list_followers_page(owner, filters, params \\ %{}, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, @browse_per_page)
    base = followers_base(owner, filters)
    total = Keyword.get(opts, :total) || Repo.aggregate(base, :count)

    base
    |> order_followers(filters)
    |> Pages.paginate(params, total, per_page)
    |> Repo.all()
  end

  @doc """
  The servers `owner`'s remote followers live on, biggest first - the
  follower browser's server filter, and the answer to "where are they coming
  from". Capped at `limit` hosts.
  """
  def follower_hosts(owner, limit \\ @browse_host_choices) do
    owner
    |> follower_scope()
    |> group_by([f], uri_host(f.actor_uri))
    |> order_by([f], desc: count(f.id), asc: uri_host(f.actor_uri))
    |> limit(^limit)
    |> select([f], %{host: uri_host(f.actor_uri), count: count(f.id)})
    |> Repo.all()
  end

  defp validated_browse_sort(sort) when sort in @browse_sort_columns, do: sort
  defp validated_browse_sort(_other), do: @browse_default_sort

  defp validated_browse_dir(dir) when dir in ~w(asc desc), do: dir
  defp validated_browse_dir(_other), do: nil

  defp normalize_browse_server(nil), do: nil
  defp normalize_browse_server(host), do: String.downcase(host)

  # The one place a follower query names its owner's column. A member's
  # followers hang off `user_id` and a page's off `organization_id` — the
  # nullable pair again — so every browser query goes through here rather than
  # writing the `where` itself.
  defp follower_scope(%User{id: id}), do: from(f in Follower, where: f.user_id == ^id)

  defp follower_scope(%Organization{id: id}),
    do: from(f in Follower, where: f.organization_id == ^id)

  defp followers_base(owner, filters) do
    owner
    |> follower_scope()
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

  defp contains(term), do: SearchText.contains(String.trim_leading(term, "@"))

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
  How many distinct remote **accounts** follow anything on this installation —
  a member, a page or a topic.

  The people half of the top bar's total (`Vutuv.PeopleCounter`), which is why
  it counts accounts and not rows: `fediverse_followers` holds one row per
  (actor, followed thing), so one Mastodon account subscribed to two members
  and three tags owns five rows and is one person. `Repo.aggregate(Follower,
  :count)` — what `stats/0` reports as `remote_followers` — is the *follow*
  figure and stays that; this is the head count.

  Actors on our own hosts (the site, its `www.` alias, the tag host) are left
  out. Nothing writes such a row today, but if one ever arrives it names
  somebody who is already in the member half, and counting them here would be
  the very double count this function exists to avoid.

  Zero while the fediverse is switched off (an intranet installation): rows
  stored before the switch describe follows no server can act on any more, so
  they are not reach.
  """
  def distinct_follower_count do
    if enabled?() do
      Repo.one(from(f in foreign_followers(), select: count(f.actor_uri, :distinct))) || 0
    else
      0
    end
  end

  @doc """
  How many **servers** those followers come from — the other half of the reach
  figure `distinct_follower_count/0` gives, and the one that says the network
  is wide rather than one busy instance. Same gates: own hosts excluded, zero
  while the fediverse is switched off.

  Uncapped, unlike `inbound_hosts/1`, which answers a table with a row limit.
  """
  def follower_host_count do
    if enabled?() do
      Repo.one(from(f in foreign_followers(), select: count(uri_host(f.actor_uri), :distinct))) ||
        0
    else
      0
    end
  end

  @doc """
  Both reach figures from one pass over the followers, for the page that states
  them together (`VutuvWeb.AgentDocs.InvestorsDoc`). Same gates as the two
  functions above; `%{accounts: 0, hosts: 0}` while the fediverse is off.
  """
  def follower_reach do
    if enabled?() do
      Repo.one(
        from(f in foreign_followers(),
          select: %{
            accounts: count(f.actor_uri, :distinct),
            hosts: count(uri_host(f.actor_uri), :distinct)
          }
        )
      ) || %{accounts: 0, hosts: 0}
    else
      %{accounts: 0, hosts: 0}
    end
  end

  # Follows from actors that are not us. The `coalesce` is load-bearing:
  # `NULL not in (…)` is NULL, so without it every row whose actor URI has no
  # parseable host would be dropped from every one of these counts.
  defp foreign_followers do
    from(f in Follower,
      where: fragment("coalesce(?, '')", uri_host(f.actor_uri)) not in ^own_hosts()
    )
  end

  @doc """
  Every spelling of "this installation" a stored actor URI could carry, as
  plain lowercase hosts for a SQL comparison — the list `own_host?/1` answers
  for one URI at a time.

  `main_host` is for the `people_snapshots` backfill, which reconstructs
  `distinct_follower_count/0` for past days in raw SQL and has to exclude the
  same hosts rather than spell the rule a second time — but runs in a migration,
  where `VutuvWeb.Endpoint.host/0` raises because the endpoint is not started.
  It reads the config itself and hands the answer in. Nothing in `lib/` passes
  it, and nothing new should: `site_host/0` below answers pre-boot too. The
  parameter stays because that migration has shipped and its meaning is frozen.
  """
  def own_hosts(main_host \\ nil) do
    host = String.downcase(main_host || site_host())

    [host, tag_host(host)]
    |> Enum.flat_map(&[&1, "www." <> &1, String.replace_prefix(&1, "www.", "")])
    |> Enum.uniq()
  end

  # This installation's main host, for the three "is this us" rules below — the
  # endpoint's answer, or its configuration when the endpoint cannot answer yet.
  #
  # `Endpoint.host/0` reads a `:persistent_term` the endpoint writes when it
  # starts and **raises** until then, and the endpoint is the last child in
  # `Vutuv.Application`. So anything running earlier gets an exception instead of
  # a host: `Vutuv.PeopleCounter` starts near the top of that list and seeds its
  # Fediverse slot with a zero-delay message, whose first
  # `distinct_follower_count/0` reached `own_hosts/0` and took the process down
  # on every cold boot (issue #1777). Boot order is the supervisor's business,
  # so the host rule learned to answer early rather than the child list being
  # reshuffled around it.
  #
  # The endpoint stays the fast path deliberately. Its `host/0` is a
  # `:persistent_term` read that copies nothing (measured 0.038us); the config
  # fallback copies the whole 427-word endpoint keyword list out of ETS
  # (0.804us, 21x). That gap would be charged per link and per mention, because
  # `local_host?/1` is what `VutuvWeb.Markdown` and `Vutuv.Mentions` ask about
  # every address in every rendered post. An unraised `rescue` costs 0.004us.
  #
  # Same value either way: Phoenix derives `host/0` from `url: [host: …]` with
  # `"localhost"` as the default, which is exactly what the fallback spells.
  defp site_host do
    VutuvWeb.Endpoint.host()
  rescue
    RuntimeError -> Application.get_env(:vutuv, VutuvWeb.Endpoint, [])[:url][:host] || "localhost"
  end

  # Members in good standing who opted in — the SQL mirror of `federated?/1`.
  # The good-standing arm delegates to `Vutuv.Moderation.Query.account_hidden_row/1`
  # (the one spelling of frozen/deactivated/suspended), so a changed suspension
  # boundary is edited in one place instead of drifting from `federated?/1` here.
  defp federating_member_count do
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
  How many posts a **page** has published (issue #1334) — what its `outbox`
  collection reports.

  No denial check, unlike the member twin: an organization post carries no
  audience by construction, so every one of them is public.
  """
  def organization_public_post_count(%Organization{id: id}),
    do: Repo.aggregate(from(p in Post, where: p.organization_id == ^id), :count)

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
  The distinct inboxes a member's or page's activities go to: one per server
  where the remote declared a sharedInbox (however many followers live there),
  else the per-actor inbox.
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

  def delivery_inboxes(%Organization{id: id}) do
    Repo.all(
      from(f in Follower,
        where: f.organization_id == ^id,
        distinct: true,
        select: coalesce(f.shared_inbox_uri, f.inbox_uri)
      )
    )
  end

  # The distinct inboxes of the accounts this member **follows** (issue #1160).
  #
  # Deliberately separate from `delivery_inboxes/1` and never used for posts: an
  # account somebody follows never asked to receive their writing. It exists for
  # the one message those servers do have to hear — "this actor is gone" — so a
  # deleted or removed member stops being delivered to from the other side too.
  defp followed_inboxes(%User{id: user_id}) do
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
    * `:local_account` — the address is on one of this installation's own hosts
      but names nothing here (a typo, a renamed handle, a tag that never
      existed).
    * `:own_account` — the address is the member's very own. Nobody follows
      themselves, on either network.
    * `:instance_blocked` — the operator shut that server out.
    * `:follow_capped` — the hourly budget is spent.
    * `:follow_limit` — the member is at `max_remote_follows/0`.
    * `:already_following` — there is a row for this pair already (the same
      answer whether the pair is a remote follow or a vutuv one).
    * `:unreachable_actor` — WebFinger answered but the actor document did not.

  **An address on one of our own hosts never federates**, so instead of a
  signed request to ourselves it becomes the local thing the member asked for:

    * a member here → a plain vutuv follow, `{:ok, {:local_follow, member}}`
      (`follow_local_member/2`);
    * a topic on our tag host (`@php@tags.<our host>`, issue #1330) → a plain
      tag subscription, `{:ok, {:local_tag_follow, tag}}`
      (`follow_local_tag/2`). A member who reads "follow @php@tags.vutuv.de" in
      a post and pastes it here means "subscribe me to #php", and that address
      is the only spelling the post can offer a reader on another network.

  Doing the real thing beats both the request to ourselves and a refusal that
  sends the member off to do it by hand.

  The state a remote row starts in is `requested`, because that is the truth:
  an account that approves its followers by hand may never answer, and a page
  that showed "Following" for a request nobody accepted would be lying.
  """
  def follow_remote(%User{} = user, address) do
    case local_follow_target(address) do
      :remote ->
        with :ok <- check_can_follow(user),
             :ok <- check_follow_limit(user),
             {:ok, account} <- resolve_remote_account(user, address) do
          send_follow(user, account)
        end

      # A vutuv follow needs no actor key and spends no outbound budget, so
      # none of the Fediverse gates apply — only the installation switch, which
      # is what put the member on a Fediverse surface in the first place.
      {:member, member} ->
        with :ok <- check_can_resolve(), do: follow_local_member(user, member)

      {:tag, tag} ->
        with :ok <- check_can_resolve(), do: follow_local_tag(user, tag)

      :unknown ->
        with :ok <- check_can_resolve(), do: {:error, :local_account}
    end
  end

  @doc """
  A member follows an account this installation **already holds**: the account
  page (`/system/fediverse/account/:id`) and the card a looked-up post arrives
  with both have the row in front of them, so neither has anything to look up.

  Separate from `follow_remote/2`, and that is the whole point. That one takes
  what somebody *typed* and works out who it names — parse the address, ask
  WebFinger for the actor id. Handing it a stored `actor_uri` instead looked
  like the same act and was not: `parse_address/1` accepts exactly the three
  shapes people paste (`@you@server`, `you@server`, `https://server/@you`), and
  a real actor id is under no obligation to be one of them.
  `https://social.isarosc.de/ap/users/116970588627792798` is an ordinary
  Mastodon-family actor with one path segment too many and no handle in it at
  all, so pressing "Follow" answered *"That does not look like an address on
  another network"* about an account whose card was right above the button.

  Widening the parser is not the fix: its narrowness is load-bearing, because
  `look_up_post/2` tells an account URL from a post URL by exactly the segment
  count it refuses (see `classify_lookup/2`). So this takes the identity we
  hold rather than a string to re-derive it from.

  The actor document is still fetched, because the inbox and the key are what
  the `Follow` is delivered and signed against and a stored row can be old.
  What is gone is the WebFinger hop, which had nothing left to prove — the
  row's `actor_uri` *is* the canonical id, either resolved through WebFinger
  once already or read off a signature-verified inbound activity. The gates and
  the refusal vocabulary are `follow_remote/2`'s, in the same order and
  including the hourly budget: a follow sent from a page is the same outbound
  act as one sent from the address box, and a cap one surface does not count is
  not a cap.
  """
  def follow_remote_account(%User{} = user, %RemoteAccount{} = account) do
    with :ok <- check_can_follow(user),
         :ok <- check_follow_limit(user),
         :ok <- check_follow_host(account.actor_uri),
         :ok <- claim_remote_follow_budget(user),
         {:ok, remote} <- fetch_follow_target(account.actor_uri, user),
         :ok <- check_follow_host(remote.id),
         {:ok, fresh} <- upsert_remote_account(remote) do
      send_follow(user, fresh)
    end
  end

  # The row plus the signed request, shared by both ways in so a follow sent
  # from a page and one sent from the address box cannot drift apart.
  defp send_follow(%User{} = user, %RemoteAccount{} = account) do
    with {:ok, follow} <- insert_remote_follow(user, account) do
      enqueue(
        user,
        [account.inbox_uri],
        Docs.follow_activity(user, account.actor_uri, follow.follow_activity_id)
      )

      {:ok, %{follow | remote_account: account}}
    end
  end

  @doc """
  The vutuv follow behind a Fediverse address that turned out to name a member
  of this very installation: a plain `Vutuv.Social.follow/2`, no signed
  request, no remote rows. `follow_remote/2` lands here by itself; the
  profile's remote-follow dialog calls it directly when the visitor's "own
  server" is this one.

  Returns `{:ok, {:local_follow, member}}`, or `{:error, :own_account}` /
  `{:error, :already_following}` / `{:error, :follow_failed}` (the social
  context refused — a block between the two).
  """
  def follow_local_member(%User{id: id}, %User{id: id}), do: {:error, :own_account}

  def follow_local_member(%User{} = user, %User{} = member) do
    if Social.user_follows_user?(user.id, member.id) do
      {:error, :already_following}
    else
      case Social.follow(user, member.id) do
        {:ok, _follow} -> {:ok, {:local_follow, member}}
        {:error, _refused} -> {:error, :follow_failed}
      end
    end
  end

  @doc """
  The same for a **page** (issue #1334): a member typed an address on this very
  vutuv into an organization page's remote-follow box, so what they asked for is
  a plain vutuv follow of that page.

  Answers in `follow_local_member/2`'s vocabulary so one caller can speak to
  both — minus `:own_account`, which cannot arise: a member is never a page.
  `Social.follow_organization/2` is idempotent by design (the pill is a toggle),
  so the already-following case is asked before, not read off the result.
  """
  def follow_local_organization(%User{} = user, %Organization{} = organization) do
    if Social.follows_organization?(user, organization) do
      {:error, :already_following}
    else
      case Social.follow_organization(user, organization) do
        {:ok, _follow} -> {:ok, {:local_follow, organization}}
        {:error, _refused} -> {:error, :follow_failed}
      end
    end
  end

  @doc """
  The vutuv **tag subscription** behind a Fediverse address that turned out to
  name a topic of this very installation (`@php@tags.<our host>`, issue #1330):
  a plain `Vutuv.Tags.follow_tag/2`, no signed request, no remote rows.

  The tag twin of `follow_local_member/2`, and there for the same reason. A tag
  actor lives on *our* tag host, so a Follow could only ever be vutuv signing a
  request to itself — which is precisely what `own_host?/1` refuses. Refusing
  was therefore the whole answer, and a dead end for the one thing the member
  asked for; doing the real thing is better than sending them off to find the
  tag page and press a different button.

  Answers in `follow_local_member/2`'s vocabulary so one caller speaks to both.
  `Tags.follow_tag/2` is idempotent by design (the pill is a toggle), so the
  already-following case is asked before, not read off the result.
  """
  def follow_local_tag(%User{} = user, %Tag{} = tag) do
    if Tags.tag_followed?(user, tag) do
      {:error, :already_following}
    else
      case Tags.follow_tag(user, tag) do
        {:ok, _tag_follow} -> {:ok, {:local_tag_follow, tag}}
        {:error, _refused} -> {:error, :follow_failed}
      end
    end
  end

  @doc """
  The member of this installation a pasted Fediverse address names, or nil —
  nil for every remote address too, so it doubles as "is this one of ours, and
  whose". Pure string work plus one lookup; no network.

  The account lookup page uses it to send an address that names a member to
  their profile instead of explaining why vutuv will not fetch itself.
  """
  def local_member_for_address(address) do
    case local_follow_target(address) do
      {:member, member} -> member
      _ -> nil
    end
  end

  @doc """
  The **tag** of this installation a pasted Fediverse address names, or nil —
  the topic twin of `local_member_for_address/1`, answering nil for a member
  address and for every remote one.

  Canonical: an address naming an alias of a merged topic (issue #1338) answers
  the tag the alias points at, so a subscription and a link both land on the
  page that actually holds the posts.
  """
  def local_tag_for_address(address) do
    case local_follow_target(address) do
      {:tag, tag} -> tag
      _ -> nil
    end
  end

  # Whether the pasted address stays on this installation, answered before any
  # Fediverse gate: `{:member, user}` when it names a member here, `{:tag, tag}`
  # when it names a topic on our tag host, `:unknown` when one of our hosts owns
  # it but nothing here answers to that name, `:remote` for everything else
  # (including whatever does not parse — the remote chain owns those refusals).
  #
  # Both of our hosts are asked, because both are us: the apex carries the
  # member/page handle namespace and `tags.<host>` carries the topics (issue
  # #1330). Asking only the apex is what left a tag address falling through to
  # the remote chain, where it could only be refused.
  defp local_follow_target(address) do
    case RemoteFollow.parse_address(address) do
      {:ok, {name, host}} -> local_host_target(name, host)
      _ -> :remote
    end
  end

  defp local_host_target(name, host) do
    cond do
      local_host?(host) -> member_target(name)
      tag_host?(host) -> tag_target(name)
      true -> :remote
    end
  end

  defp member_target(name) do
    case Accounts.get_user_by_username(Handles.normalize(name)) do
      %User{} = member -> {:member, member}
      nil -> :unknown
    end
  end

  # A tag slug is lowercase (`^[a-z0-9_]+$`, issue #1332), and a pasted address
  # may not be, so it is downcased like the handle beside it.
  #
  # `resolve_tag_by_slug/1`, not `get_canonical_tag_by_slug/1`: the strict one
  # guards what vutuv *publishes* as an actor (one topic, one address), while
  # this is a member telling us which topic they meant — and an old spelling
  # they copied out of an old post should reach the topic, exactly as the tag
  # page's 301 and the `#hashtag` link already take them there.
  defp tag_target(name) do
    case Tags.resolve_tag_by_slug(String.downcase(name)) do
      %Tag{} = tag -> {:tag, tag}
      nil -> :unknown
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
  def resolve_remote_account(follower, address) do
    with :ok <- check_can_resolve(),
         {:ok, {_name, host}} <- RemoteFollow.parse_address(address),
         :ok <- check_follow_host(host),
         :ok <- claim_remote_follow_budget(follower),
         {:ok, actor_uri} <- RemoteFollow.resolve_actor(address),
         :ok <- check_follow_host(actor_uri),
         {:ok, remote} <- fetch_follow_target(actor_uri, follower),
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
  The stored remote accounts these actor URIs name, keyed by URI — one query
  for a whole page. A URI nobody here stored is simply absent, so callers
  fall back per actor.
  """
  def remote_accounts_by_uris(actor_uris) do
    case actor_uris |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] ->
        %{}

      uris ->
        from(a in RemoteAccount, where: a.actor_uri in ^uris)
        |> Repo.all()
        |> Map.new(&{&1.actor_uri, &1})
    end
  end

  @doc """
  The member or page takes the follow back: a best-effort `Undo(Follow)` to
  the other server, then the row goes.

  The row is deleted whether or not the Undo can be sent, because it describes
  *our* member's or page's intent and they have withdrawn it; a server that
  never hears about it simply stops being followed the moment we stop
  accepting its deliveries.
  """
  def unfollow_remote(owner, follow_id) do
    case get_remote_follow(owner, follow_id) do
      nil ->
        {:error, :not_found}

      follow ->
        undo_remote_follow(owner, follow)
        Repo.delete(follow)
        # The cached posts existed because somebody here followed the author
        # (issue #1161). If nobody does any more, they go now rather than at the
        # next sweep.
        purge_unfollowed_remote_posts([follow.remote_account_id])
        :ok
    end
  end

  @doc """
  The same withdrawal, named by the **account** instead of by the follow row —
  what a post's ⋯ menu has in hand. Scoped to the party's own follow, so an
  account id from anywhere resolves to nothing but their row, and
  `{:error, :not_found}` when they do not follow it at all.
  """
  def unfollow_remote_account(owner, remote_account_id) do
    follow =
      UUIDv7.with_cast(remote_account_id, fn account_id ->
        Repo.one(
          from(f in Follow, where: party_is(f, owner) and f.remote_account_id == ^account_id)
        )
      end)

    case follow do
      nil -> {:error, :not_found}
      follow -> unfollow_remote(owner, follow.id)
    end
  end

  @doc """
  Which of these remote accounts the party follows, as a `MapSet` of account ids
  — one query for a whole feed.

  What the card menus branch on: Mute and Unfollow both act on a follow, and a
  feed carries posts by accounts nobody here follows (a boost by a followed
  account, a member's reshare). Offering either one there is a control that does
  nothing and a flash that says otherwise.

  A follow that has only been **asked** for counts here, because both those
  controls still act on a pending row — which is exactly why this is not a read
  gate. `readable_remote_post_ids/2` is the one that answers what may be read.
  """
  def followed_remote_account_ids(party, account_ids),
    do: remote_follow_account_ids(party, account_ids, :any)

  # The shared body of the two questions above and below: which of `account_ids`
  # this party holds a follow of, either any follow at all or an accepted one.
  defp remote_follow_account_ids(party, account_ids, state) do
    case account_ids |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] ->
        MapSet.new()

      ids ->
        from(f in Follow,
          where: party_is(f, party) and f.remote_account_id in ^ids,
          select: f.remote_account_id
        )
        |> scope_follow_state(state)
        |> Repo.all()
        |> MapSet.new()
    end
  end

  defp scope_follow_state(query, :accepted), do: where(query, [f], f.state == "accepted")
  defp scope_follow_state(query, :any), do: query

  @doc """
  The remote-account ids whose follow this party has muted.

  The small half of the picture, like `Vutuv.Social.muted_follow_ids/1`, and for
  the same reason: it is what an undo of a bulk mute has to put back.
  """
  def muted_remote_follow_ids(party) do
    Repo.all(
      from(f in Follow, where: party_is(f, party) and f.muted, select: f.remote_account_id)
    )
  end

  @doc """
  Mutes this party's follows of every account on `host` except `keep_id`, which
  is unmuted — the feed band's "only this account", scoped to the one server the
  account sits on.

  Scoped rather than global on purpose. Accounts on the *other* servers are
  switched off by muting those hosts, one array entry each, and a mute written
  onto them here as well would outlive that: the reader would tick a server back
  on and it would deliver nothing, with no row in the card admitting why.

  Writes over mutes the member made deliberately, so the caller captures
  `muted_remote_follow_ids/1` first and offers an undo.
  """
  def mute_remote_follows_except(party, host, keep_id) when is_binary(host) do
    UUIDv7.with_cast(keep_id, fn account_id ->
      stamp = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

      on_host =
        from(f in Follow,
          join: a in RemoteAccount,
          on: a.id == f.remote_account_id,
          where: party_is(f, party) and a.host == ^host
        )

      Repo.update_all(
        from([f, _a] in on_host, where: not f.muted and f.remote_account_id != ^account_id),
        set: [muted: true, updated_at: stamp]
      )

      Repo.update_all(
        from([f, _a] in on_host, where: f.muted and f.remote_account_id == ^account_id),
        set: [muted: false, updated_at: stamp]
      )
    end)

    :ok
  end

  @doc """
  Puts this party's remote-follow mutes back to exactly `ids` — every other
  follow unmuted. The undo of `mute_remote_follows_except/3`, and what the
  band's "Select all" runs with an empty list.
  """
  def restore_remote_follow_mutes(party, ids) when is_list(ids) do
    stamp = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    Repo.update_all(
      from(f in Follow,
        where: party_is(f, party) and f.muted and f.remote_account_id not in ^ids
      ),
      set: [muted: false, updated_at: stamp]
    )

    Repo.update_all(
      from(f in Follow,
        where: party_is(f, party) and not f.muted and f.remote_account_id in ^ids
      ),
      set: [muted: true, updated_at: stamp]
    )

    :ok
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
  def set_remote_follow_mute(party, remote_account_id, muted?) do
    UUIDv7.with_cast(remote_account_id, fn account_id ->
      Repo.update_all(
        from(f in Follow,
          where: party_is(f, party) and f.remote_account_id == ^account_id
        ),
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
  The member's or page's follow of one remote account, or nil — what the
  account page's button branches on.
  """
  def remote_follow_for(%User{id: user_id}, %RemoteAccount{id: account_id}) do
    Repo.get_by(Follow, user_id: user_id, remote_account_id: account_id)
  end

  def remote_follow_for(%Organization{id: id}, %RemoteAccount{id: account_id}) do
    Repo.get_by(Follow, organization_id: id, remote_account_id: account_id)
  end

  # One of the member's or page's own follows, with the remote account
  # preloaded, or nil. Scoped to the owner, so an id from somebody else's
  # page resolves to nothing.
  defp get_remote_follow(%User{id: user_id}, follow_id) do
    UUIDv7.with_cast(follow_id, fn id ->
      Repo.one(
        from(f in Follow,
          where: f.id == ^id and f.user_id == ^user_id,
          preload: [:remote_account]
        )
      )
    end)
  end

  defp get_remote_follow(%Organization{id: page_id}, follow_id) do
    UUIDv7.with_cast(follow_id, fn id ->
      Repo.one(
        from(f in Follow,
          where: f.id == ^id and f.organization_id == ^page_id,
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

      # The successor of a move answering yes is what completes the swap: the
      # husk left behind on the old account goes now, and not before (issue
      # #1168). A move the successor never answers keeps the record of what the
      # member had.
      settle_moved_follows(user, actor_uri)

      broadcast_remote_follows_changed([user.id])
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
    if follow = find_answered_follow(user, activity, actor_uri) do
      Repo.delete(follow)
      broadcast_remote_follows_changed([user.id])
    end

    :ok
  end

  @doc """
  The other server said yes to a **page's** Follow (issue #1336).

  Its own pair rather than a widened member one: the member versions also settle
  a moved account and broadcast to the member's open following browser, and a
  page has neither. What they share is `find_answered_follow/3`, which is where
  the row is actually identified.
  """
  def accept_organization_remote_follow(%Organization{} = page, activity, actor_uri) do
    if follow = find_answered_follow(page, activity, actor_uri) do
      follow |> Follow.accept() |> Repo.update()
    end

    :ok
  end

  @doc "The other server said no to a page's Follow: the row goes, like the member twin."
  def reject_organization_remote_follow(%Organization{} = page, activity, actor_uri) do
    if follow = find_answered_follow(page, activity, actor_uri) do
      Repo.delete(follow)
    end

    :ok
  end

  # Tells these members' open following browsers
  # (`/settings/fediverse/following`) that their list of accounts elsewhere
  # changed underneath them.
  #
  # Every change on that page except the member's own follow and unfollow
  # arrives from **another server**, at a time nobody here picks: an `Accept`
  # may be seconds or days behind the request, a `Reject` or a `Delete` comes
  # with no warning at all. So the one page that shows a follow's *state* is
  # also the one page in /settings that cannot be a snapshot — left to a
  # reload, "Requested" reads as the current answer long after the other side
  # said yes.
  #
  # A bare signal, not a payload: the page reloads its own view (which is
  # filtered, sorted and paged, and none of that is knowable from here) rather
  # than patching a row. `VutuvWeb.FediverseFollowingLive` listens; every other
  # subscriber of the owner topic ignores it through its catch-all
  # `handle_info/2`.
  defp broadcast_remote_follows_changed(user_ids) when is_list(user_ids) do
    user_ids
    |> Enum.uniq()
    |> Enum.each(&Activity.broadcast(&1, :remote_follows_changed))
  end

  # The same thing for the **other** direction: who follows the member from out
  # there (`/settings/fediverse/followers`, `Vutuv.Fediverse.Follower`), which
  # moves when a `Follow` arrives, an `Undo` withdraws one, an actor `Update`
  # renames somebody, the pruner drops an account that is gone, or an operator
  # blocks its server. The two signals are named for the two tables and are
  # never interchangeable — `follows` is what the member does, `followers` is
  # what is done to them.
  defp broadcast_remote_followers_changed(user_ids) when is_list(user_ids) do
    user_ids
    |> Enum.uniq()
    |> Enum.each(&Activity.broadcast(&1, :remote_followers_changed))
  end

  ## Telling open feeds that something landed on the other tab (issue #1503)

  # A bare "go and look", never a payload: an open /feed sitting on the tab this
  # did NOT land on asks its own sources whether the arrival reaches this
  # particular reader (`Vutuv.Posts.feed_source_since?/3`) and dots the other
  # tab if it does. It has to ask, because mute, a follow still merely
  # requested, a narrowed audience, the reader's language filter and the
  # resharer's standing all decide per member — none of which is knowable from
  # the write. `at` is the stamp the entry will carry in the merged feed
  # (naive UTC, like every `Vutuv.FeedPage` entry), so the reader's own newest
  # row can be compared against it.
  #
  # Every other subscriber of the member topic ignores this through its
  # catch-all `handle_info/2`, exactly like `:remote_follows_changed` above.
  defp nudge_feeds(user_ids, %NaiveDateTime{} = at) do
    event = {:remote_feed_arrival, %{at: at}}

    user_ids
    |> Enum.uniq()
    |> Enum.each(&Activity.broadcast(&1, event))
  end

  # Who to nudge when an account out there posts: the members following it here
  # with the follow unmuted. Mute is the one per-member gate this can answer
  # itself — it hangs off the very row being joined — and answering it here
  # spares every muted follower a message and a probe. `user_id` is null for a
  # page's follow (issue #1336); a page has no open feed to dot.
  defp followers_of_account(%RemoteAccount{id: account_id}, filters \\ []) do
    from(f in Follow,
      where: f.remote_account_id == ^account_id and f.muted == false,
      where: not is_nil(f.user_id),
      select: f.user_id
    )
    |> accepted_only(filters[:accepted])
    |> Repo.all()
  end

  defp accepted_only(query, true), do: where(query, [f], f.state == "accepted")
  defp accepted_only(query, _any), do: query

  # Who to nudge when a member here passes something on: themselves (their own
  # reshare is a row in their own feed) plus everyone whose follow of them is
  # unmuted — the audience `feed_remote_reposts/3` and its note twin scope to.
  defp resharer_audience(%User{id: user_id}) do
    followers =
      Repo.all(
        from(f in Vutuv.Social.Follow,
          where: f.followee_id == ^user_id and f.muted == false,
          select: f.follower_id
        )
      )

    [user_id | followers]
  end

  # The members here who follow one of these remote accounts. Read **before** a
  # delete of those accounts: their follows cascade away with them, so asked
  # afterwards the answer is always "nobody" and the page never hears about it.
  defp remote_follow_user_ids(accounts) do
    Repo.all(
      from(f in Follow,
        join: a in subquery(accounts),
        on: a.id == f.remote_account_id,
        distinct: true,
        select: f.user_id
      )
    )
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
  The same figure for a page: how many accounts on other networks it follows.

  An aggregate, because both callers only ever wanted the number — they took
  `length(list_organization_remote_follows/1)`, which loads every follow row
  **with its `:remote_account` preloaded** and sorts them, for a list whose
  length the page itself sets. On a timeline that renders several pages, that is
  an unbounded read per page per request.
  """
  def organization_remote_follow_count(%Organization{id: id}) do
    Repo.aggregate(from(f in Follow, where: f.organization_id == ^id), :count)
  end

  @doc """
  `remote_follow_count/1` for many members at once, as `%{user_id => count}`.

  The batched twin the Mastodon client API needs: a member's "following" figure
  is the local follows plus these, and that endpoint fills the figure for every
  account it embeds in a page of statuses — one query for the page rather than
  one per row.
  """
  def remote_follow_counts([]), do: %{}

  def remote_follow_counts(user_ids) when is_list(user_ids) do
    from(f in Follow,
      where: f.user_id in ^user_ids,
      group_by: f.user_id,
      select: {f.user_id, count(f.id)}
    )
    |> Repo.all()
    |> Map.new()
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
    # And the ones on replies under vutuv posts (issue #1270), which are the
    # same act on a different table and must not survive the same decision —
    # those rows do not hang off a follow at all, so nothing else would ever
    # take them.
    drop_note_likes(user)
    # And what they passed on (issue #1275). A reshare stands on other people's
    # servers under this member's name, so it goes with the decision to leave
    # exactly as the cached-post boosts do.
    drop_note_reposts(user)

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
    log_account_gone(actor_uri, accounts)
    follow_owners = remote_follow_user_ids(from(a in accounts, select: %{id: a.id}))

    # The rows cascade, the files do not: the account's own picture and every
    # picture on the posts we cached for it have to be swept before the delete
    # takes away the ids that name them.
    wipe_media(
      from(p in RemotePost, join: a in ^subquery(accounts), on: p.remote_account_id == a.id)
    )

    wipe_avatars(accounts)
    Repo.delete_all(accounts)
    broadcast_remote_follows_changed(follow_owners)
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
      own_host?(uri) -> {:error, :local_account}
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
      host -> same_site?(host, String.downcase(site_host()))
    end
  end

  @doc """
  The host a **topic's** actor lives on: `tags.<our host>` (issue #1330).

  Its own WebFinger authority, and that is the whole reason for it. Members and
  pages share one handle namespace (`Vutuv.Handles`), tags are member-creatable,
  and `ReservedSlugs` guards only route words — so a tag `elixir` and a member
  `elixir` would otherwise want the same address. A separate host cannot
  collide, and needs no reserved-prefix list anybody has to maintain.

  Configurable per installation (`FEDIVERSE_TAG_HOST`), defaulting to the `tags.`
  subdomain of whatever `PHX_HOST` says, so nothing has to be set to run this
  elsewhere. What an installation does owe is the DNS record, the certificate
  and an nginx server name — see `docs/ADMINS.md`.

  `main_host` is for the frozen migration that reaches this through
  `own_hosts/1` (see there); nothing in `lib/` passes it.
  """
  def tag_host(main_host \\ nil) do
    Application.get_env(:vutuv, :fediverse_tag_host) ||
      "tags." <> String.downcase(main_host || site_host())
  end

  @doc "Whether `uri` names this installation's tag host."
  def tag_host?(uri) do
    case BlockedInstance.normalize_host(uri) do
      nil -> false
      host -> same_site?(host, tag_host())
    end
  end

  @doc """
  Whether `uri` is **this installation at all** — the main host or the tag host.

  Deliberately a third function rather than a widening of `local_host?/1`.
  That one is shared with `local_path/1`, which asks the narrower question
  "which member or page of ours does this URL name", and a tag-host URL is
  none: `https://tags.<host>/hund` would come back as the member `hund`.

  This is what the questions about the installation as a whole ask — the follow
  gate, the search page's follow offer, `own_object?/3` — because signing a
  request to ourselves and waiting for an Accept our own inbox would have to
  invent is the failure v7.197.0 already produced once, via `www.`.
  """
  def own_host?(uri), do: local_host?(uri) or tag_host?(uri)

  @doc """
  The path segments of one of **our own** URLs, or nil for any other server's.

  The whole-URL counterpart of `local_host?/1` (issue #1211): parse, ask
  whether the host is ours — so the `www.`/`http`/port/case spellings of the
  same page all count — and hand back the path split on `/` with empty
  segments dropped, so a trailing slash never changes the answer (the query
  and the fragment are not in `path` at all). Every "which record does this
  URL of ours name" reader pattern-matches these segments instead of
  prefix-matching `Endpoint.url()`, which misses every alternate spelling.
  """
  def local_path(url) when is_binary(url) do
    with true <- local_host?(url),
         %URI{path: path} <- URI.parse(url) do
      String.split(path || "", "/", trim: true)
    else
      _ -> nil
    end
  end

  def local_path(_), do: nil

  # `www.` is not another installation. Serving a site at both the apex and its
  # `www.` alias is the oldest convention on the web, and every caller here asks
  # "is this us", never "is this byte-identical to the configured host" — so an
  # exact match sent all four of them the wrong answer for an address a member
  # can perfectly well paste: the follow gate offered to follow this vutuv from
  # itself, the search page offered the same, `own_object?/3` accepted a
  # document attributing a post to one of our own actors, and the post lookup
  # made a signed GET to our own server (issue #1211, found in production).
  # Nothing about it is vutuv.de-specific.
  defp same_site?(host, host), do: true
  defp same_site?(host, other), do: strip_www(host) == strip_www(other)

  defp strip_www("www." <> rest), do: rest
  defp strip_www(host), do: host

  # Keyed on whoever is asking — a member or a page (issue #1336) — so a page
  # gets its own hourly budget rather than spending somebody's.
  defp claim_remote_follow_budget(%User{id: id}), do: claim_remote_follow_budget(id)

  defp claim_remote_follow_budget(%Organization{id: id}), do: claim_remote_follow_budget(id)

  defp claim_remote_follow_budget(id) when is_binary(id) do
    case RateLimiter.hit(
           {:fediverse_remote_follow, id},
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

  # The same ceiling for a page (issue #1601): a cap one follower kind does not
  # count is not a cap.
  defp check_follow_limit(%Organization{} = page) do
    if organization_remote_follow_count(page) >= max_remote_follows(),
      do: {:error, :follow_limit},
      else: :ok
  end

  # Signed with the follower's own key: instances in authorized-fetch mode
  # refuse an anonymous GET, and this is the one fetch we make on their behalf.
  defp fetch_follow_target(actor_uri, follower) do
    case fetch_remote_actor(actor_uri, signer(follower)) do
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
    :avatar_source,
    # Where the account went (issue #1168). Nothing an actor document carries
    # sets it, so leaving it out would null a verified move on the next repeat
    # resolve — one stored reply from the old actor, or one member looking the
    # old address up — and with it the link the successor's `Accept` follows to
    # settle the husk, and the guard that keeps a moved account out of the
    # prune rotation. The same trap the three avatar columns above sit here for.
    :moved_to
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

  @doc """
  A **page** follows an account on another network (issue #1336's last point).

  Blocked until #1334 gave a page an actor: a Follow has to be signed by
  somebody. Narrower than the member twin on purpose — no local-address branch,
  because "follow a vutuv member" for a page is `Social.follow_as_organization/2`
  and belongs on the page's own controls, not behind a fediverse address box.
  """
  def follow_remote_as_organization(%Organization{} = page, address) do
    with :ok <- check_can_resolve(),
         true <- federated?(page),
         :ok <- check_follow_limit(page),
         {:ok, account} <- resolve_remote_account(page, address),
         {:ok, follow} <- insert_remote_follow(page, account) do
      enqueue(
        page,
        [account.inbox_uri],
        Docs.follow_activity(page, account.actor_uri, follow.follow_activity_id)
      )

      {:ok, %{follow | remote_account: account}}
    else
      false -> {:error, :not_federated}
      other -> other
    end
  end

  @doc "The accounts `page` follows out there, newest first."
  def list_organization_remote_follows(%Organization{id: id}) do
    Repo.all(
      from(f in Follow,
        where: f.organization_id == ^id,
        order_by: [desc: f.inserted_at, desc: f.id],
        preload: [:remote_account]
      )
    )
  end

  # One head per follower kind (issue #1416); only the owner column differs.
  # The activity id names the row, so the id is minted before the insert
  # rather than read back after it: an `Accept` finds its follow by this
  # string and by nothing else.
  defp insert_remote_follow(follower, %RemoteAccount{} = account) do
    id = UUIDv7.generate()

    follower
    |> new_remote_follow(id, account)
    |> Follow.changeset(%{
      state: "requested",
      follow_activity_id: Docs.follow_activity_id(follower, id)
    })
    |> Repo.insert()
    |> case do
      {:ok, follow} -> {:ok, follow}
      {:error, _changeset} -> {:error, :already_following}
    end
  end

  defp new_remote_follow(%User{} = user, id, account),
    do: %Follow{id: id, user_id: user.id, remote_account_id: account.id}

  defp new_remote_follow(%Organization{} = page, id, account),
    do: %Follow{id: id, organization_id: page.id, remote_account_id: account.id}

  defp undo_remote_follow(owner, %Follow{} = follow),
    do: undo_remote_follows(owner, [follow])

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
  defp undo_remote_follows(_owner, []), do: :ok

  defp undo_remote_follows(owner, follows) do
    if enabled?() and ever_federated?(owner) do
      blocked = blocked_hosts()

      follows
      |> Enum.filter(&deliverable_undo?(&1, blocked))
      |> Enum.map(fn %Follow{remote_account: account} = follow ->
        {account.inbox_uri,
         Docs.undo_follow_activity(owner, account.actor_uri, follow.follow_activity_id)}
      end)
      |> enqueue_each(owner)
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
  defp find_answered_follow(follower, activity, actor_uri) when is_binary(actor_uri) do
    base =
      from(f in Follow,
        join: a in RemoteAccount,
        on: a.id == f.remote_account_id,
        where: a.actor_uri == ^actor_uri
      )
      |> scope_follower(follower)

    case activity_object_id(activity["object"]) do
      id when is_binary(id) ->
        Repo.one(from(f in base, where: f.follow_activity_id == ^id)) || Repo.one(base)

      _ ->
        Repo.one(base)
    end
  end

  defp find_answered_follow(_user, _activity, _actor_uri), do: nil

  # Which side's follows to look in. Named rather than inlined because the
  # answer must be scoped to exactly one follower — an `Accept` from one server
  # settling somebody else's request would be the whole bug.
  defp scope_follower(query, %User{id: id}), do: where(query, [f], f.user_id == ^id)

  defp scope_follower(query, %Organization{id: id}),
    do: where(query, [f], f.organization_id == ^id)

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

  # Every column `remote_text/3` writes, which is the same list
  # `strip_stored_shortcodes/0` has to clean.
  @remote_text_columns [
    {RemotePost, [:content_text, :summary]},
    {Note, [:content_text, :summary]},
    {RemoteAccount, [:summary]}
  ]

  @doc """
  Takes the custom-emoji shortcodes out of the remote text already stored, and
  reports how many values it rewrote.

  Run once, from the migration that introduced the strip.
  `Vutuv.RemoteHtml.strip_shortcodes/1` does it on the way in from that release
  on, but a cached post is written once and never re-read from its origin, so
  everything stored before it would go on showing a literal `":tux:"` until it
  aged out of its six-month retention. An account's bio would heal itself on
  the 30-day recheck; it is in here anyway, because 30 days is a long time to
  read `":tux:"` beside posts that no longer do.

  The one repair, not a second one written in SQL: the migration calls this the
  way the legacy tag and username cleanups call theirs, so a backfilled row and
  a row written tomorrow cannot come out differently.

  A cached **translation** of a rewritten value falls out on its own —
  `translations.source_sha256` keys it to the exact source string, so it stops
  matching and the post is translated again from the cleaned text.
  """
  def strip_stored_shortcodes do
    for {schema, fields} <- @remote_text_columns, field <- fields, reduce: 0 do
      total -> total + strip_stored_shortcodes(schema, field)
    end
  end

  defp strip_stored_shortcodes(schema, field) do
    # Every shortcode contains a colon, so this narrows the read to a cheap
    # superset of the grammar rather than restating it — the grammar itself
    # runs in Elixir below and decides. Reading the matches at once is bounded
    # by what these tables are: a cache the six-month retention keeps small.
    schema
    |> where([r], like(field(r, ^field), "%:%"))
    |> select([r], {r.id, field(r, ^field)})
    |> Repo.all()
    |> Enum.count(fn {id, text} -> strip_stored_value(schema, field, id, text) end)
  end

  defp strip_stored_value(schema, field, id, text) do
    case RemoteHtml.strip_shortcodes(text) do
      ^text ->
        false

      stripped ->
        schema
        |> where([r], r.id == ^id)
        |> Repo.update_all(set: [{field, stripped}])

        true
    end
  end

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
      # Only the row this delivery really wrote: the same post arrives once per
      # local follower until every server speaks to our shared inbox, and each
      # redelivery leaves the `with` as a `:skip` above, so open feeds are
      # nudged exactly once rather than once per follower squared.
      nudge_feeds(followers_of_account(account), DateTime.to_naive(post.published_at))
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

    # With the picture set on record the post's link screenshot can be decided:
    # a single-URL, picture-less, unwarned post enqueues the same durable
    # capture job a member post gets (`Vutuv.Posts.Screenshots`). Here rather
    # than beside the callers, so every path that mints a cached post — a
    # follower delivery, a boost, a URL lookup — gets it by construction.
    Screenshots.reconcile(post)
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
  # The page twin (issue #1336): what the accounts a PAGE follows out there have
  # published. Same gate as the member version, which is the part worth keeping
  # in step — a post from a locked account shows only once the follow was really
  # ACCEPTED, so a request nobody answered never leaks that account's posts.
  def organization_feed_remote_posts(%Organization{id: page_id}, fetch_n, cursor) do
    if enabled?() do
      from(p in RemotePost,
        join: a in RemoteAccount,
        on: a.id == p.remote_account_id,
        join: f in Follow,
        on: f.remote_account_id == a.id,
        where: f.organization_id == ^page_id and f.muted == false,
        where: p.audience in ^RemotePost.open_audiences() or f.state == "accepted",
        order_by: [desc: p.published_at, desc: p.id],
        limit: ^fetch_n,
        preload: [:screenshot, remote_account: a]
      )
      |> utc_at_or_before(cursor, :published_at)
      |> Repo.all()
      |> Enum.map(&remote_feed_entry/1)
    else
      []
    end
  end

  @doc """
  The public remote posts this installation holds, newest first — the federated
  half of the Mastodon-compatible public timeline.

  Viewer-independent, unlike every other reader here: a client's "Federated" tab
  asks what the *instance* knows, not what one member follows. The gate is
  therefore the strictest one, `audience == "public"` — not
  `RemotePost.open_audiences/0`, which also lets a followers-only post through
  for somebody who actually follows that account. Expired copies are left out
  the way `Vutuv.Tags.Timeline.remote_posts_query/1` leaves them out.

  Takes a `Vutuv.Keyset` window (`:max_id` / `:since_id` / `:min_id` / `:limit`),
  so it walks by the same ids the local half does — every id here is a
  `Vutuv.UUIDv7`, so ordering by id is ordering by when the post reached us,
  which is what a federated timeline is ordered by anyway.
  """
  def recent_public_remote_posts(opts \\ []) do
    if enabled?() do
      from(p in RemotePost,
        join: a in RemoteAccount,
        on: a.id == p.remote_account_id,
        where: p.audience == "public",
        where: p.expires_at > ^DateTime.utc_now(:second),
        preload: [:screenshot, remote_account: a]
      )
      |> Keyset.scope(opts)
      |> Repo.all()
      |> Keyset.restore(opts)
    else
      []
    end
  end

  @doc """
  The fediverse servers this member switched off in the feed's filter band —
  the instance-level twin of `fediverse_follows.muted`.

  Muting an account hides that one account; muting a server hides everything
  that comes from it, including accounts followed later, and including a post
  another server's account boosted into the feed. Both halves are read by the
  four fediverse feed sources; neither unfollows anything, so switching a
  server back on restores exactly what was there.

  Stored as a short array on the member (`users.feed_muted_hosts`): the list is
  a handful of hostnames, it is read beside the member row the feed already has
  in hand, and it never needs an identity of its own.
  """
  def muted_hosts(%User{feed_muted_hosts: hosts}) when is_list(hosts), do: hosts
  def muted_hosts(_viewer), do: []

  @doc """
  Switch one server off (`true`) or back on (`false`) for `user`, and answer
  with the new list.

  The host is normalised the way `RemoteAccount.host` stores it (lower case,
  trimmed), so a member typing a shouted hostname mutes the same server the
  panel lists. Idempotent in both directions.
  """
  def set_host_mute(%User{} = user, host, muted?) when is_binary(host) do
    host = host |> String.trim() |> String.downcase()
    current = muted_hosts(user)

    next =
      if muted?,
        do: Enum.uniq([host | current]),
        else: Enum.reject(current, &(&1 == host))

    set_muted_hosts(user, next)
  end

  @doc """
  Replace the whole muted-server list in one write — what the band's "select
  all" and "clear all" do. One statement rather than one per host, so the two
  bulk buttons cannot half-apply.
  """
  def set_muted_hosts(%User{} = user, hosts) when is_list(hosts) do
    next = hosts |> Enum.map(&(&1 |> String.trim() |> String.downcase())) |> Enum.uniq()

    {1, nil} =
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [feed_muted_hosts: next])

    {:ok, next}
  end

  # The three shapes the muted-server list has to be applied in. `is_nil(...) or
  # ... not in` is not belt and braces: `x NOT IN (…)` is never true when `x` is
  # NULL, so a row without a host would drop out of the feed entirely — the
  # silent half of the nullable-column trap.
  defp reject_muted_hosts(query, viewer),
    do: reject_hosts(query, :remote_account, muted_hosts(viewer))

  defp reject_muted_boosted_hosts(query, viewer),
    do: reject_hosts(query, :boosted_author, muted_hosts(viewer))

  defp reject_hosts(query, _binding, []), do: query

  defp reject_hosts(query, :remote_account, hosts),
    do: from([remote_account: a] in query, where: is_nil(a.host) or a.host not in ^hosts)

  defp reject_hosts(query, :boosted_author, hosts),
    do: from([boosted_author: a] in query, where: is_nil(a.host) or a.host not in ^hosts)

  # A reshared reply hangs off a `Note`, which stores the author as the whole
  # `@user@host` handle rather than a host column of its own — so the server is
  # read out of the handle in SQL rather than by dropping rows afterwards, which
  # would leave the paginator's `more?` lying about a short page.
  defp reject_muted_note_hosts(query, viewer) do
    case muted_hosts(viewer) do
      [] ->
        query

      hosts ->
        from([language_source: n] in query,
          where: is_nil(n.handle) or fragment("split_part(?, '@', 3)", n.handle) not in ^hosts
        )
    end
  end

  def feed_remote_posts(%User{id: viewer_id} = viewer, fetch_n, cursor) do
    if enabled?() do
      from(p in RemotePost,
        join: a in RemoteAccount,
        as: :remote_account,
        on: a.id == p.remote_account_id,
        join: f in Follow,
        on: f.remote_account_id == a.id,
        where: f.user_id == ^viewer_id and f.muted == false,
        where: p.audience in ^RemotePost.open_audiences() or f.state == "accepted",
        order_by: [desc: p.published_at, desc: p.id],
        limit: ^fetch_n,
        preload: [:screenshot, remote_account: a]
      )
      |> reject_muted_hosts(viewer)
      |> Vutuv.Posts.language_scope(Vutuv.Posts.feed_language_filter(viewer))
      |> utc_at_or_before(cursor, :published_at)
      |> Repo.all()
      |> Enum.map(&remote_feed_entry/1)
    else
      []
    end
  end

  @doc """
  The fifth feed source (issue #1166): posts from another network that people
  the viewer follows **here** have reshared.

  This is how a member who follows nobody out there meets that content at all —
  through somebody here vouching for it — so it is scoped to the reposter, not
  to any follow of the author. Stamped with the repost time, like a local
  repost: what is new is the sharing, not the post.

  It feeds the **vutuv** tab, the reader's own reshares and everybody else's
  alike: pressing that button is something that happened here, whoever pressed
  it (`Vutuv.Posts.feed_sources/2`).
  """
  def feed_remote_reposts(viewer, fetch_n, cursor, opts \\ [])

  def feed_remote_reposts(%User{id: viewer_id} = viewer, fetch_n, cursor, opts) do
    if enabled?() do
      from(r in PostRepost,
        join: p in RemotePost,
        as: :language_source,
        on: p.id == r.remote_post_id,
        join: a in RemoteAccount,
        as: :remote_account,
        on: a.id == p.remote_account_id,
        join: reposter in User,
        as: :resharer,
        on: reposter.id == r.user_id,
        # Only ever what the reposter could have shared: the audience gate is
        # the same one that let them press the button.
        where: p.audience in ^RemotePost.open_audiences(),
        order_by: [desc: r.inserted_at, desc: r.id],
        limit: ^fetch_n,
        preload: [remote_post: {p, [:screenshot, remote_account: a]}, user: reposter]
      )
      |> scope_resharer(viewer_id, Keyword.get(opts, :only))
      |> reject_muted_hosts(viewer)
      |> Vutuv.Posts.named_language_scope(Vutuv.Posts.feed_language_filter(viewer))
      |> remote_reposts_at_or_before(cursor)
      |> Repo.all()
      |> Enum.map(&remote_repost_entry/1)
    else
      []
    end
  end

  # Who may have carried a third party's words into this feed, for both reshare
  # sources (a cached post and a reply are the same act one table over).
  #
  # The viewer's own row needs no standing check — they are reading their own
  # act — while somebody else's is held to a stricter rule than the local repost
  # source applies: that one only asks about a confirmed address, and passing a
  # stranger's post into other people's feeds is exactly what a frozen or
  # suspended account must not be able to keep doing while its case is open.
  defp scope_resharer(query, viewer_id, :mine), do: where(query, [r], r.user_id == ^viewer_id)

  defp scope_resharer(query, viewer_id, :others) do
    where(
      query,
      [r, resharer: resharer],
      r.user_id != ^viewer_id and r.user_id in subquery(unmuted_followees(viewer_id)) and
        account_confirmed_row(resharer) and not account_hidden_row(resharer)
    )
  end

  defp scope_resharer(query, viewer_id, _both) do
    where(
      query,
      [r, resharer: resharer],
      r.user_id == ^viewer_id or
        (r.user_id in subquery(unmuted_followees(viewer_id)) and
           account_confirmed_row(resharer) and not account_hidden_row(resharer))
    )
  end

  # The same rule the local feed uses: a muted follow keeps the relationship and
  # drops that member's posts out of this feed — including what they reshare.
  # The `not is_nil` is not decoration: since #1336 a followed **page** leaves
  # `followee_id` NULL, so this list carries nils. Both current callers use a
  # positive `in subquery(...)`, where a nil is merely ignored — but the same
  # list negated (`not in`) is false for every row, silently, which is how the
  # discovery rail emptied itself for anyone who followed a page. Guarding here
  # means the next caller cannot inherit that, whichever way it asks.
  defp unmuted_followees(viewer_id) do
    from(f in Vutuv.Social.Follow,
      where: f.follower_id == ^viewer_id and f.muted == false,
      where: not is_nil(f.followee_id),
      select: f.followee_id
    )
  end

  defp remote_repost_entry(%PostRepost{} = repost) do
    %{
      id: "remote-repost-#{repost.id}",
      post: nil,
      remote_post: repost.remote_post,
      reposted_by: repost.user,
      at: repost.inserted_at
    }
  end

  defp remote_reposts_at_or_before(query, nil), do: query

  defp remote_reposts_at_or_before(query, %{at: at}),
    do: where(query, [r], r.inserted_at <= ^at)

  @doc """
  The sixth feed source (issue #1167): what the accounts a member follows out
  there have **re-shared**.

  Scoped to the follow of the *booster*, not of the author — the whole point is
  that a followed account passes on somebody else's post, usually somebody
  nobody here follows. Stamped with the boost time: what is new is the sharing.

  Both kinds ride the same source. A boosted **cached post** carries the remote
  card; a boosted **vutuv post** carries the local one, which is how members get
  discovered through the outside network.

  `only:` keeps just one of the two — `:remote` for the boosts of a cached
  post, `:local` for the boosts of a vutuv post — which is how the feed's
  source tabs (`Vutuv.Posts.feed_page/2`) split this source between them. It
  narrows the **query**, not the rows it returns, so a narrowed page is as
  full as an unnarrowed one.
  """
  def feed_remote_boosts(viewer, fetch_n, cursor, opts \\ [])

  def feed_remote_boosts(%User{id: viewer_id} = viewer, fetch_n, cursor, opts) do
    if enabled?() do
      # The author's own follow is consulted too, not only the booster's: a
      # reader who muted an account out there muted *them*, and somebody else
      # passing their post on is exactly the back door that would undo it.
      muted_authors =
        from(f in Follow,
          where: f.user_id == ^viewer_id and f.muted == true,
          select: f.remote_account_id
        )

      from(b in PostBoost,
        join: a in RemoteAccount,
        as: :remote_account,
        on: a.id == b.remote_account_id,
        join: f in Follow,
        on: f.remote_account_id == a.id,
        left_join: rp in RemotePost,
        as: :language_source,
        on: rp.id == b.remote_post_id,
        # The boosted post's own author, for the muted-server check below: a
        # switched-off instance must not come back in through somebody else's
        # boost, the same back door the muted-author subquery closes.
        left_join: author in RemoteAccount,
        as: :boosted_author,
        on: author.id == rp.remote_account_id,
        where: f.user_id == ^viewer_id and f.muted == false and f.state == "accepted",
        where: is_nil(rp.id) or rp.remote_account_id not in subquery(muted_authors),
        order_by: [desc: b.announced_at, desc: b.id],
        limit: ^fetch_n,
        # A boosted vutuv post carries `denials` (the card's 🔒 marker reads
        # them) and its author (`filter_visible_boosts/2`'s moderation check
        # reads the struct instead of re-fetching the user per row); the rest
        # a card needs is preloaded once for the whole page by `Vutuv.Posts`.
        preload: [
          remote_account: a,
          remote_post: [:remote_account, :screenshot],
          post: [:denials, :user]
        ]
      )
      |> boosts_of_kind(opts[:only])
      |> reject_muted_hosts(viewer)
      |> reject_muted_boosted_hosts(viewer)
      |> Vutuv.Posts.named_language_scope(Vutuv.Posts.feed_language_filter(viewer))
      |> utc_at_or_before(cursor, :announced_at)
      |> Repo.all()
      |> Enum.map(&boost_entry/1)
      |> filter_visible_boosts(viewer)
    else
      []
    end
  end

  # Which of the two things a boost can point at. `remote_post_id` is the one
  # that decides it — a boost carries exactly one of the two ids — so the split
  # reads it rather than the left-joined row.
  defp boosts_of_kind(query, :remote), do: where(query, [b], not is_nil(b.remote_post_id))
  defp boosts_of_kind(query, :local), do: where(query, [b], is_nil(b.remote_post_id))
  defp boosts_of_kind(query, _both), do: query

  # One entry shape for both kinds. Exactly one of the two references is set on
  # a row, so which card the feed renders follows from the boost itself
  # (`Posts.remote_feed_entry?/1` asks for the cached post).
  defp boost_entry(%PostBoost{} = boost) do
    %{
      id: "boost-#{boost.id}",
      post: boost.post,
      remote_post: boost.remote_post,
      boosted_by: boost.remote_account,
      reposted_by: nil,
      at: DateTime.to_naive(boost.announced_at)
    }
  end

  # Whatever the boost still points at may have gone or changed since. A remote
  # post can have been narrowed by an `Update` (`RemotePost.open?/1`, answered
  # in memory); a **local** post has to pass the viewer's own visibility rules
  # in full — a boost must not be a way around an audience restriction, a
  # moderation freeze, an image still with the AI gate or an author whose
  # account is hidden. Blocks are the one half post visibility does not own —
  # they live in the feed queries, and this source is the only one that reaches
  # a local post without going through them (a third party's reshare must not
  # carry a blocked author's post into the viewer's feed, and here the third
  # party is on another server entirely).
  #
  # Both local checks are resolved for the whole page at once instead of per
  # row: one `Posts.scope_visible/2` id-set query (the SQL twin of
  # `Posts.visible_to?/2`) plus one blocked-pairs query, where the per-row
  # `visible_to?/2` + `blocked_between?/2` pair used to cost up to three
  # queries for every boosted member post on the page. The one arm the scope
  # does not carry is `visible_to?/2`'s admin bypass — an admin may see a
  # moderation-hidden post — so that arm stays as the in-memory
  # `Posts.moderation_hidden?/1` check (the author rides the preload above,
  # so it costs no query).
  defp filter_visible_boosts(entries, %User{id: viewer_id} = viewer) do
    local_posts = for %{post: %Post{} = post} <- entries, do: post
    visible_ids = visible_boost_post_ids(local_posts, viewer)
    blocked_author_ids = blocked_boost_author_ids(local_posts, viewer_id)
    # The language filter's local half (issue #1461): the boost query joins
    # only the CACHED post (scoped in-query), so a boosted vutuv post is
    # checked here with the other in-memory gates. NULL never hides.
    chosen = Posts.feed_language_filter(viewer)

    Enum.filter(entries, fn
      %{remote_post: %RemotePost{} = post} ->
        RemotePost.open?(post)

      %{post: %Post{} = post} ->
        (MapSet.member?(visible_ids, post.id) or
           (viewer.admin? == true and Posts.moderation_hidden?(post))) and
          not MapSet.member?(blocked_author_ids, post.user_id) and
          Posts.language_visible?(post.language, chosen)

      _entry ->
        false
    end)
  end

  defp visible_boost_post_ids([], _viewer), do: MapSet.new()

  defp visible_boost_post_ids(posts, viewer) do
    ids = Enum.map(posts, & &1.id)

    from(p in Post, where: p.id in ^ids, select: p.id)
    |> Posts.scope_visible(viewer)
    |> Repo.all()
    |> MapSet.new()
  end

  # The authors among the page's boosted member posts that stand in a block
  # with the viewer, either direction — the set form of
  # `Social.blocked_between?/2`. Every returned row names the viewer on one
  # side, so the counterpart is always the author.
  defp blocked_boost_author_ids([], _viewer_id), do: MapSet.new()

  defp blocked_boost_author_ids(posts, viewer_id) do
    author_ids = posts |> Enum.map(& &1.user_id) |> Enum.uniq()

    viewer_id
    |> Social.blocks_involving()
    |> where([b], b.blocker_id in ^author_ids or b.blocked_id in ^author_ids)
    |> select([b], {b.blocker_id, b.blocked_id})
    |> Repo.all()
    |> MapSet.new(fn {blocker_id, blocked_id} ->
      if blocker_id == viewer_id, do: blocked_id, else: blocker_id
    end)
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

  # The cursor for a source ordered by a `utc_datetime` column — a followed
  # account's post by its publication time, a boost by when it was announced.
  # The merged feed stamps its entries as **naive** UTC (`Vutuv.FeedPage`) while
  # these columns carry a zone, so the conversion lives here once instead of
  # once per source.
  defp utc_at_or_before(query, nil, _field), do: query

  defp utc_at_or_before(query, %{at: at}, field),
    do: where(query, [r], field(r, ^field) <= ^DateTime.from_naive!(at, "Etc/UTC"))

  @doc "One stored remote picture with its post, or nil."
  def get_remote_image(id) do
    UUIDv7.with_cast(id, &Repo.get(RemoteImage, &1)) |> Repo.preload(:remote_post)
  end

  @doc """
  Whether `viewer` may see a cached picture: exactly whether they may **read**
  the post it hangs off (`remote_post_readable?/2`).

  A picture URL is the one thing a reader can hand to somebody else, so the
  proxy re-asks this per request rather than trusting that a card rendered it.

  **Readable, not "would it reach them unprompted".** This used to ask for the
  viewer's own follow of the *author*, which is only one of the four ways a
  cached post is shown. A **boost** (issue #1167) and a member's **repost**
  (issue #1166) both carry a post to readers who follow nobody but the sharer —
  that is their entire purpose, and the purge even spares such a copy for it —
  and the account page (`account_posts/2`) shows any open post to any signed-in
  member. So the card rendered and every picture on it 404ed: a boosted photo
  post came out as a row of broken images. Each of those surfaces is a subset of
  "readable" (all three require an open audience, or the viewer's own accepted
  follow), so asking the read question covers them with nothing left to widen —
  a followers-only post still needs the viewer's own accepted follow.
  """
  def remote_image_visible?(%RemoteImage{remote_post: %RemotePost{} = post}, viewer),
    do: remote_post_readable?(post, viewer)

  def remote_image_visible?(_image, _viewer), do: false

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
  def list_remote_images([]), do: %{}

  def list_remote_images(post_ids) do
    from(i in RemoteImage,
      where: i.remote_post_id in ^post_ids,
      order_by: [asc: i.position, asc: i.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.remote_post_id)
  end

  @doc """
  Every picture recorded for one cached post, in the author's order.

  The singular of `list_remote_images/1`, and the same deliberate lack of a
  filter: a row here is not a permission (see above). It exists because six
  surfaces draw these pictures and each of them re-reads one post's set when a
  verdict lands, which was `Map.get(list_remote_images([id]), id, [])` written
  out four times.
  """
  def remote_images(remote_post_id) when is_binary(remote_post_id),
    do: [remote_post_id] |> list_remote_images() |> Map.get(remote_post_id, [])

  @doc """
  The topic every open page listens on for a picture leaving the AI gate
  (issue #1801).

  **One** topic rather than one per waiting post, the arrangement
  `counts_topic/0` makes and for the same reason: a verdict is rare (a few an
  hour on a busy installation, against a counts refresh every couple of
  minutes), and each listener keeps only the cards it is showing. The
  alternative — subscribing per picture that happens to be waiting — makes
  every one of those six surfaces walk its own entries at mount and again on
  every page append, which is a great deal of bookkeeping for an event this
  quiet.
  """
  def remote_images_topic, do: @remote_images_topic

  @doc "Listen for pictures leaving the AI gate. See `remote_images_topic/0`."
  def subscribe_remote_images, do: Phoenix.PubSub.subscribe(Vutuv.PubSub, @remote_images_topic)

  @doc """
  Tells every open page that one of a cached post's pictures has left the AI
  gate (issue #1801).

  **Both verdicts**, because both change the row a card was drawn from: an
  approval swaps the picture in for the waiting tile, a rejection clears the
  file. What the tile then *says* about a rejected picture is a separate
  question and still the wrong answer — it goes on claiming a check is running
  for a picture that will never arrive.

  Until this existed the verdict was a database flip and nothing else. Every
  other image kind announces itself through
  `Vutuv.Activity.broadcast(scan.owner_user_id, …)`, and a picture we fetched
  has no owner here, so a card kept whatever it was first drawn with. That is
  not a corner case: a delivery records the picture and nudges the open feeds
  in the same breath, a second before the bytes land, so the *first* draw of a
  boosted photo post is the wordless "picture is being checked" tile — and
  without this it was also the last.

  **A remote account's avatar is deliberately not announced**, though it is the
  other ownerless scan kind and goes just as quiet: an avatar the gate has not
  cleared renders as the account's initials, which is a whole placeholder
  rather than a promise, so nobody is left waiting on it. If that changes, this
  is the topic it joins.

  `nil` is a no-op, the way every notification chokepoint here takes a missing
  recipient: the retention sweep can take the post while the model is still
  looking at its picture.
  """
  def broadcast_remote_images_settled(remote_post_id) when is_binary(remote_post_id) do
    Phoenix.PubSub.broadcast(
      Vutuv.PubSub,
      @remote_images_topic,
      {:remote_images_settled, %{remote_post_id: remote_post_id}}
    )
  end

  def broadcast_remote_images_settled(_remote_post_id), do: :ok

  @doc """
  The **cached reply** each of `post_ids` answers, keyed by post id (issue
  #1641). Posts that answer no stored reply are simply absent.

  One query for a whole page rather than one per row, because the caller is the
  Mastodon adapter's page renderer, which bundles everything else it reads the
  same way.

  **Deliberately not read off the `:remote_reply_ref` preload.** Half the
  callers hand over posts straight from a query, and an answer whose parent
  silently depends on whether somebody remembered a preload is the shape that
  has bitten this codebase before.

  **Public replies only, and that is the whole gate** — no viewer is needed and
  none may be assumed. `check_remote_reply/2` refuses to let a member answer a
  reply that was addressed to them alone, so a private note here can only be one
  an upstream `Update` narrowed afterwards; naming it would hand a client an id
  that answers 404 to everybody but the member whose post it hangs under, and
  the local parent is the honest fallback for all of them.
  """
  def answered_notes([]), do: %{}

  def answered_notes(post_ids) when is_list(post_ids) do
    from(r in PostRemoteReply,
      join: n in subquery(notes_with_account()),
      on: n.id == r.note_id,
      where: r.post_id in ^post_ids and n.audience == "public",
      select: {r.post_id, n}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The same, widened to the **cached post** half of the sidecar (issue #1165), so
  one map answers "what does this post answer out there" for a whole thread.

  The two halves are gated differently and the caller has to know it: a reply
  comes back public-only (see `answered_notes/1`), while a cached post carries
  its own audience and is gated by whoever is rendering — the only one that
  knows the reader and whether they follow that account.
  """
  def answered_objects([]), do: %{}

  def answered_objects(post_ids) when is_list(post_ids),
    do: Map.merge(answered_notes(post_ids), answered_remote_posts(post_ids))

  defp answered_remote_posts(post_ids) do
    from(r in PostRemoteReply,
      join: p in RemotePost,
      on: p.id == r.remote_post_id,
      join: a in RemoteAccount,
      on: a.id == p.remote_account_id,
      where: r.post_id in ^post_ids,
      select: {r.post_id, %{p | remote_account: a}}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The cached post `post` continues, or `nil` when we hold no such row.

  A stored remote reply only ever continues a thread of the **same** account,
  which is `own_thread?/2`'s rule and why both read one query
  (`same_account_post/2`): a reply is kept solely when its parent is already one
  of that account's cached posts. So the scope here is not a precaution against
  a missing row, it is what the column means — and it is what lets the client
  API name a followed account's self-reply with an id the same client can fetch.
  """
  def remote_parent_post(%RemotePost{in_reply_to_uri: uri, remote_account_id: account_id})
      when is_binary(uri) and is_binary(account_id) do
    Repo.one(from([p, a] in same_account_post(uri, account_id), select: %{p | remote_account: a}))
  end

  def remote_parent_post(%RemotePost{}), do: nil

  # "That account's own cached post with this object URI" — the predicate
  # `own_thread?/2` decides a reply by and `remote_parent_post/1` resolves it
  # with. One builder, so the invariant the second relies on stays the first's.
  defp same_account_post(uri, account_id) do
    from(p in RemotePost,
      join: a in RemoteAccount,
      on: a.id == p.remote_account_id,
      where: p.object_uri == ^uri and p.remote_account_id == ^account_id
    )
  end

  @doc """
  `remote_parent_post/1`'s lookup batched for a whole page of `%RemotePost{}`
  items (issue #1622's Mastodon-adapter case, which — unlike `/context`'s
  one-post-at-a-time walk — renders many self-replies at once and cannot afford
  a query per row). The **same rows**, without the singular's `remote_account`:
  the callers here name an id and never render the account.

  `pairs` is a list of `{in_reply_to_uri, remote_account_id}`, exactly what
  `own_thread?/2` gates a stored reply's parent by — so the result keys the
  same way, and a caller with no candidate pairs pays no query. `object_uri`
  carries a unique index, so the two `IN` lists can only narrow each other; the
  same-account rule is the map key, which is what a caller looks a pair up by.
  """
  def remote_parent_posts([]), do: %{}

  def remote_parent_posts(pairs) when is_list(pairs) do
    uris = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    account_ids = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    from(p in RemotePost, where: p.object_uri in ^uris and p.remote_account_id in ^account_ids)
    |> Repo.all()
    |> Map.new(&{{&1.object_uri, &1.remote_account_id}, &1})
  end

  @doc "One cached remote post with its account and screenshot, or nil."
  def get_remote_post(id) do
    UUIDv7.with_cast(id, &Repo.get(RemotePost, &1))
    |> Repo.preload([:remote_account, :screenshot])
  end

  @doc """
  What a reshare row named, or `nil` — the lookups behind the ids a reshare
  carries in the client API (`Vutuv.MastodonApi.Presenter.reshared/2`).

  Three tables, because vutuv has three ways a post is passed on: a member here
  reshares a cached post (`fediverse_post_reposts`), a member here reshares a
  cached reply (`fediverse_note_reposts`), and an account out there boosts
  something (`fediverse_post_boosts`, which points at either a cached post or a
  post of ours — exactly one of the two, so the answer follows the row).

  Unscoped like their local twin: the caller re-asks whether the reader may see
  what comes back.
  """
  def get_reposted_remote_post(id) do
    with %PostRepost{remote_post_id: post_id} <- get_remote_post_repost(id) do
      get_remote_post(post_id)
    end
  end

  def get_reposted_note(id) do
    with %NoteRepost{note_id: note_id} <- get_note_repost(id), do: get_note(note_id)
  end

  def get_boosted_object(id) do
    case UUIDv7.with_cast(id, &Repo.get(PostBoost, &1)) do
      %PostBoost{remote_post_id: post_id} when is_binary(post_id) -> get_remote_post(post_id)
      %PostBoost{post_id: post_id} when is_binary(post_id) -> Vutuv.Posts.get_post(post_id)
      _no_such_boost -> nil
    end
  end

  @doc """
  The reshare **rows** those same ids name, or `nil` — the act rather than what
  it passed on, for a caller that has to know *whose* reshare it is before
  undoing one (`VutuvWeb.MastodonApi.Statuses`). Unscoped like the lookups
  above: the caller compares the row's owner with the identity it is acting as.

  There is no twin for `fediverse_post_boosts` — that row belongs to an account
  on another server and can never be the caller's act.
  """
  def get_remote_post_repost(id), do: UUIDv7.with_cast(id, &Repo.get(PostRepost, &1))

  def get_note_repost(id), do: UUIDv7.with_cast(id, &Repo.get(NoteRepost, &1))

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

  Rate limited per reporter (`@remote_post_report_limit` a day).
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

  # Deletes the stored files of the pictures on `post_ids`, before their rows go.
  #
  # The rows cascade with their post, but files do not: a deletion that leaves
  # bytes at rest is not a deletion, so every path that removes cached posts goes
  # through here first — the bulk sweeps (expiry, the unfollow purge, an instance
  # block, a deleted account) call it via `wipe_media/1`, and every single-post
  # delete goes through `delete_cached_post/1`, which is the one place a post row
  # is removed.
  defp delete_media_for_posts(post_ids) when is_list(post_ids) do
    # The auto link screenshots go with the pictures: same "nothing at rest
    # for a post nobody can reach" promise, same chokepoint.
    Screenshots.delete_for_remote_posts(post_ids)

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
    withdraw_reposts(post)
    delete_media_for_posts([post.id])
    Repo.delete(post)
  end

  # Every reshare of this post is withdrawn before the row goes (issue #1166).
  # The rows cascade, the `Announce` on other servers does not: without this a
  # member's boost keeps standing under their name out there after our copy was
  # deleted — and in the two cases that matter most (a member reported it, or
  # its author narrowed the audience upstream) that is precisely the amplifying
  # we were asked to stop. The same shape revocation takes everywhere here.
  defp withdraw_reposts(%RemotePost{} = post) do
    account = post_account(post)

    from(r in PostRepost,
      join: u in User,
      on: u.id == r.user_id,
      where: r.remote_post_id == ^post.id,
      select: u
    )
    |> Repo.all()
    |> Enum.each(fn reposter ->
      deliver_boost(
        reposter,
        %{post | remote_account: account},
        &Docs.undo_announce_remote_activity/4
      )
    end)
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

  # Everything that still holds a cached post whose author nobody follows any
  # more:
  #
  #   * a member here **reshared** it (issue #1166) — `spare_reposted/2`, the
  #     same exemption (and the same "only while the verification is current"
  #     rule) the ceiling sweep applies, so the two can never disagree;
  #   * a followed account **boosted** it (issue #1167) — nobody here follows
  #     its author, which is the normal case for a boost, and the boost is the
  #     whole reason the copy exists.
  #   * a member here **looked it up** by its URL (issue #1211) — the same
  #     situation as a boost and the commoner one, since the lookup page works
  #     on any account: a copy fetched precisely because nobody follows its
  #     author would otherwise be swept within the hour, while the member who
  #     asked for it is still reading it.
  #
  # None of the three buys extra time: they only buy the right to live out the
  # ordinary clock instead of being swept the moment the last follower of the
  # author walks away. The `:post` alias comes from `spare_reposted/2`, which is
  # why the other two are added on top of it rather than beside it.
  defp spare_held(query) do
    boosted = from(b in PostBoost, where: b.remote_post_id == parent_as(:post).id)
    looked_up = from(l in PostLookup, where: l.remote_post_id == parent_as(:post).id)

    query
    |> spare_reposted(RemotePost)
    |> where([p], not exists(boosted))
    |> where([p], not exists(looked_up))
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
    # A reshared copy is spared here too (issue #1166), not only at the
    # ceiling. Its life is tied to the reshare and to the original still being
    # published — not to anybody's follow — so the last follower of its author
    # leaving must not pull it out from under the people reading it in the
    # resharer's feed.
    query = spare_held(query)

    # Files first: the rows cascade, bytes on disk do not, and a deletion that
    # leaves a stranger's photograph at rest is not a deletion (issue #1163).
    wipe_media(query)
    {count, _} = Repo.delete_all(query)
    count
  end

  # How many cached posts are stored across the installation.
  defp remote_post_total, do: Repo.aggregate(RemotePost, :count)

  # How many of an account's cached posts the account page shows. It is a
  # preview — "what do they actually post", the thing that decides a follow —
  # not an archive of somebody else's writing, and the page says so when there
  # is more.
  @account_page_posts 30

  @doc """
  The cached posts of one account for `viewer`, newest first, as
  `{posts, more?}` (issue #1162).

  Audience-scoped exactly like the feed: public and unlisted for any signed-in
  member or organization identity, followers-only solely when that identity's
  own follow is **accepted**. So the page cannot become a way to read what an
  author addressed to somebody else's followers.

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

    account_posts_query(account_id, accepted)
  end

  def account_posts(%RemoteAccount{id: account_id}, %Organization{id: organization_id}) do
    accepted =
      from(f in Follow,
        where:
          f.remote_account_id == ^account_id and f.organization_id == ^organization_id and
            f.state == "accepted"
      )

    account_posts_query(account_id, accepted)
  end

  defp account_posts_query(account_id, accepted) do
    from(p in RemotePost,
      where: p.remote_account_id == ^account_id,
      # The feed's vocabulary, not a negated literal: `open_audiences/0` is the
      # one list the query and the card (`RemotePost.open?/1`) both read, so a
      # fourth audience value cannot open here and close there.
      where: p.audience in ^RemotePost.open_audiences() or exists(accepted),
      order_by: [desc: p.published_at, desc: p.id],
      limit: ^(@account_page_posts + 1),
      preload: [:screenshot]
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

  # What each remote server has stored here as cached posts, biggest first —
  # the third column of the operator's `/admin/fediverse` picture, beside the
  # follower and reply volumes. Capped at `limit` hosts.
  defp remote_post_hosts(limit) do
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
  defp own_thread?(%{"inReplyTo" => parent}, %RemoteAccount{} = account) when is_binary(parent),
    do: Repo.exists?(same_account_post(parent, account.id))

  defp own_thread?(_object, _account), do: true

  defp insert_remote_post(%RemoteAccount{} = account, object, audience) do
    received = DateTime.utc_now(:second)

    with uri when is_binary(uri) <- SearchText.normalize_search(object["id"]),
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
          origin_url: SearchText.normalize_search(object["url"]),
          kind: remote_post_kind(object),
          published_at: published_at(object["published"], received),
          received_at: received,
          expires_at: DateTime.add(received, remote_post_retention_days() * 86_400)
        })
      )
      |> put_object_counts(object)
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:object_uri])
      |> stored_post(uri)
      |> file_hashtags(object)
    else
      _ -> :error
    end
  end

  # File the post under the tags its hashtags name, so it reaches `/tags/:slug`
  # (`Vutuv.Fediverse.Hashtags`). Done here rather than at the three call sites,
  # so a fourth ingestion path cannot forget it — and only for the row **this**
  # delivery wrote: a redelivery (`{:exists, _}`) is the same post arriving once
  # per follower, already filed.
  defp file_hashtags({:ok, %RemotePost{} = post}, object),
    do: {:ok, Hashtags.sync(post, object)}

  defp file_hashtags(result, _object), do: result

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
  # A redelivery is `{:exists, post}`, which the `Create` path drops so a post's
  # pictures are recorded exactly once, while the announce path (issue #1167)
  # takes the row it names instead of asking for it a second time.
  defp stored_post({:ok, %RemotePost{id: minted_id}}, uri) do
    case Repo.get_by(RemotePost, object_uri: uri) do
      %RemotePost{id: ^minted_id} = post -> {:ok, post}
      %RemotePost{} = post -> {:exists, post}
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
      language: as2_language(object),
      sensitive: object["sensitive"] == true,
      audience: audience
    }
  end

  @doc """
  The language an AS2 object declares (issue #1488): the first key of
  `contentMap`, else `nameMap`, else `summaryMap`, else the `@context`'s
  `@language` — read through `Vutuv.Translations.cast_language/1`, so nil for
  anything absent, malformed, or outside the curated list. Mastodon's own
  parser takes the first `contentMap` key the same way; genuinely multilingual
  maps are read by nobody. ONE named function instead of a copy per
  `object["content"]` read site.

  Curated and not merely well-formed, because Mastodon's own language picker
  offers tags this installation's chips do not (`eo`, `nb`, `nn`, `tok`):
  stored, such a code would be hidden from every hide-mode reader with no chip
  that could bring it back, while NULL is simply always shown.
  """
  def as2_language(object) when is_map(object) do
    raw =
      first_language_key(object["contentMap"]) ||
        first_language_key(object["nameMap"]) ||
        first_language_key(object["summaryMap"]) ||
        context_language(object["@context"])

    Vutuv.Translations.cast_language(raw)
  end

  def as2_language(_object), do: nil

  defp first_language_key(map) when is_map(map), do: map |> Map.keys() |> List.first()
  defp first_language_key(_other), do: nil

  defp context_language(list) when is_list(list), do: Enum.find_value(list, &context_language/1)
  defp context_language(%{"@language" => language}), do: language
  defp context_language(_other), do: nil

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

    [
      remote_text(object["content"], RemotePost.max_content(), object["tag"]),
      SearchText.normalize_search(options)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> SearchText.normalize_search()
  end

  defp remote_post_text(object),
    do: remote_text(object["content"], RemotePost.max_content(), object["tag"])

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
          # A `name` is plain text, so this is the one path into `content_text`
          # that never reaches `RemoteHtml.to_text/3` and has to take the emoji
          # strip itself — otherwise the next edit writes `• :tux: Linux` back
          # over the cleaned row.
          text = strip_option_shortcodes(option["name"]),
          name = SearchText.normalize_search(text),
          do: name

    Enum.take(options, 20)
  end

  defp strip_option_shortcodes(name) when is_binary(name),
    do: RemoteHtml.strip_shortcodes(name)

  defp strip_option_shortcodes(_name), do: nil

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
        # An edit is also where a hashtag is added or taken out, so the filings
        # are re-synced rather than left at what the original text said — a post
        # that drops `#berlin` drops off that tag page.
        Hashtags.sync(updated, object)

        # An edit is where a picture is added, dropped, described or covered —
        # see `Media.sync_attachments/3`.
        updated
        |> Media.sync_attachments(List.wrap(object["attachment"]), RemotePost.warned?(updated))
        |> Media.fetch_async()

        # …and where the single URL, the picture set or the content warning can
        # change, each of which enqueues, refreshes or cancels the screenshot.
        Screenshots.reconcile(updated)
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
    organization_actors = actors_by_organization_id(due)
    tag_actors = actors_by_tag_id(due)

    count_pruned(
      due,
      &check_follower(&1, follower_actor(&1, actors, organization_actors, tag_actors), now)
    )
  end

  # The key this re-check signs with belongs to whoever is being followed, so a
  # page's and a topic's followers are checked with their own actor rather than
  # with nothing. Without this the fetch went out unsigned, an authorized-fetch
  # server answered 401, and 401 is not a "gone" status — so the dead row was
  # kept and re-checked forever. Mirrors `signing_actor/4` on the delivery path.
  defp follower_actor(%Follower{organization_id: id}, _actors, organization_actors, _tag_actors)
       when is_binary(id),
       do: organization_actors[id]

  defp follower_actor(%Follower{tag_id: id}, _actors, _organization_actors, tag_actors)
       when is_binary(id),
       do: tag_actors[id]

  defp follower_actor(%Follower{user_id: id}, actors, _organization_actors, _tag_actors),
    do: actors[id]

  # Each check is one blocking HTTPS round trip (no DB connection held during
  # it), so run a few at a time instead of summing every remote's latency. Both
  # directions of the rotation (followers here, followed accounts out there)
  # share the bound, so neither can quietly outgrow the other.
  defp count_pruned(rows, check) do
    rows
    |> Task.async_stream(check, max_concurrency: 5, timeout: 30_000, on_timeout: :kill_task)
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
      preload: [:user, :organization, :tag]
    )
    |> Repo.all()
    |> spread_across_hosts(&(BlockedInstance.normalize_host(&1.actor_uri) || &1.actor_uri))
  end

  # One run's fair share, in the order the query asked for (stalest first): the
  # first @prune_per_host rows of any one server, then the first @prune_batch of
  # what is left. `host_of` is how a row names its server — parsed out of the
  # actor URI for a follower, a stored column for a followed account.
  defp spread_across_hosts(rows, host_of) do
    rows
    |> Enum.reduce({[], %{}}, fn row, {kept, per_host} ->
      host = host_of.(row)
      taken = Map.get(per_host, host, 0)

      if taken < @prune_per_host,
        do: {[row | kept], Map.put(per_host, host, taken + 1)},
        else: {kept, per_host}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.take(@prune_batch)
  end

  defp check_follower(%Follower{} = follower, actor, now) do
    case fetch_remote_actor(follower.actor_uri, signer_for(followed(follower), actor)) do
      {:error, {:http, status}} when status in @gone_statuses ->
        prune_follower(follower, status)

      _ ->
        touch_follower(follower, now)
    end
  end

  defp prune_follower(%Follower{} = follower, status) do
    Repo.delete(follower)
    broadcast_remote_followers_changed([follower.user_id])

    # The ledger row carries the SAME owner the follower row did (member, page
    # or topic). It used to copy `user_id` whatever the follower was, so a
    # page's or a topic's removal hit the NOT NULL on that column and raised —
    # after the follower had already been deleted, which is the worst order:
    # the removal happened and the report never heard about it.
    #
    # The host is always parseable here (an unparseable actor URI never gets as
    # far as an HTTP status), but fall back rather than lose the ledger row: a
    # deletion the report cannot see is exactly what this is meant to prevent.
    %FollowerPrune{
      user_id: follower.user_id,
      organization_id: follower.organization_id,
      tag_id: follower.tag_id
    }
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

  # One clause for all three kinds: `Docs.key_id/1` is `actor_url/1` plus
  # `#main-key`, and `actor_url/1` dispatches on the subject itself.
  defp signer_for(subject, %Actor{} = actor) when not is_nil(subject),
    do: {Docs.key_id(subject), actor.private_key_pem}

  defp signer_for(_subject, _actor), do: nil

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

  # Reposts a member may send out per hour (issue #1166). Between the two above:
  # a boost is a publishing act, not a tap, but it is still one press while
  # reading rather than a piece of writing.
  @outbound_boost_limit 100

  # How long a reposted cached post may go unverified before its origin is asked
  # again. A repost is what keeps such a copy alive past the six-month ceiling,
  # so this is the clock that keeps "cache" honest for exactly those rows.
  @repost_recheck_days 7

  # How long a reshared copy may go **unverified** before it stops being spared
  # from the retention sweeps. Comfortably more than one recheck interval, so an
  # origin that is merely slow or briefly offline never costs anybody their
  # reshare — but bounded, so a backlog drains itself instead of accumulating.
  @repost_recheck_stale_days 30

  # Dereferences of announced objects per remote host, per hour (issue #1167).
  # A followed account boosting is the one inbound activity that makes this
  # installation fetch from a **third** server it never spoke to, on an address
  # that server did not choose, so it is metered per host: one busy relay must
  # not be able to walk us through a stranger's whole archive.
  @announce_fetch_limit 60

  # Posts a member may look up by URL per hour (issue #1211). Per member rather
  # than per host, because this is somebody's own reading and the address is
  # theirs to choose: what has to be bounded is one account turning the
  # installation into a crawler, not the traffic any one server sees. Sized for
  # a person following links out of a conversation; a cached post costs nothing
  # from it, so re-opening the same one is free however often it happens.
  @lookup_limit 30

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
    # Whose follower tables are about to lose rows, asked while they still exist.
    followed_members =
      Repo.all(
        from(f in Follower,
          where: uri_host(f.actor_uri) == ^host,
          distinct: true,
          select: f.user_id
        )
      )

    {followers, _} =
      Repo.delete_all(from(f in Follower, where: uri_host(f.actor_uri) == ^host))

    broadcast_remote_followers_changed(followed_members)

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

    # Which members are about to lose follows, asked while the rows still
    # exist. Named for the members it holds, not `followers` — that is already
    # this function's count of the rows pointing the *other* way, and the
    # returned tally would silently become a list of member ids.
    follow_owners =
      remote_follow_user_ids(
        from(a in RemoteAccount, where: a.host == ^host, select: %{id: a.id})
      )

    {remote_accounts, _} =
      Repo.delete_all(from(a in RemoteAccount, where: a.host == ^host))

    broadcast_remote_follows_changed(follow_owners)

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
  Every local **actor** a delivery to the shared inbox is for (issue #1073) — a
  member, a page (issue #1334) or a topic (issue #1330), as structs the caller
  dispatches on.

  All three kinds have to be here because all three **advertise this endpoint**:
  `endpoints.sharedInbox` is a fact about the installation, so every actor
  document we serve carries it, and Mastodon (like most implementations) then
  prefers it over the actor's own inbox for everything it delivers. While this
  resolved members only, every signed activity a server sent for a page or a
  topic resolved to nobody and was dropped — a `Follow` of a page, a favourite
  of its post, and (as reported) an **answer** to its post, which simply never
  appeared here. The page's own `/organizations/:slug/inbox` was not the path
  those deliveries took.

  The per-member inbox learns who the activity is for from the URL; the shared
  one has to read it out of the activity. Three sources, because that is where
  ActivityPub actually puts it:

    * the **addressing** — `to` / `cc` / `bto` / `bcc` / `audience` on the
      activity and on its object — plus the object itself and, for an `Undo`,
      the object it wraps: a `Follow` names an actor URL, a `Like` or
      `Announce` a Note URL, a reply its `inReplyTo`. Every URL of ours resolves
      to the member, page or topic it hangs off.
    * the **remote actor's own lifecycle** (`Update`/`Delete` of itself), which
      names no local member at all: it is broadcast to everyone with a stake in
      that actor, so the addressees are the members it follows here **and**
      (issue #1160) the members who follow it. This is the case the endpoint is
      worth having for — one account deletion used to mean one signed delivery
      per member.
    * an author's **`Update`/`Delete` of a note they wrote**, which likewise
      names nobody here: the addressees are the members whose posts hold a
      stored copy of it.

  Those last two remain **member-only** on purpose, and it is a known gap rather
  than a decision: they are about the accounts somebody here follows, and a page
  can follow too since #1336, so a lifecycle broadcast about an account only a
  page follows still resolves to nobody. It costs a page's copy of a renamed or
  deleted remote account, not an answer to one of its posts, and the join behind
  it (`fediverse_followers` inner-joined through `users`) is the second half of
  that fix rather than this one.

  Actors that do not federate (a member suspended, frozen or gone, a page or
  topic with its switch off) are filtered out, so a delivery to them is silently
  dropped — never answered differently, or the endpoint would become a way to
  ask who takes part.

  `actor_uri` is the activity's *claimed* actor. The caller resolves recipients
  before the signature is verified (it needs one of their keys to sign the
  actor fetch that verification depends on) and only acts on the result
  afterwards, once that claim is proven.
  """
  def inbox_recipients(activity, actor_uri) when is_map(activity) do
    (addressed_actors(activity) ++ lifecycle_users(activity, actor_uri))
    # By kind AND id: three tables, so an id alone is not the identity here.
    |> Enum.uniq_by(&{&1.__struct__, &1.id})
    |> Enum.filter(&federated?/1)
  end

  def inbox_recipients(_activity, _actor_uri), do: []

  defp addressed_actors(activity) do
    object = if is_map(activity["object"]), do: activity["object"], else: %{}

    # `object["actor"]` is what names us in an `Accept`/`Reject` (issue #1160):
    # the answer wraps the Follow we sent, whose actor is our own member, and
    # nothing else in the document mentions them.
    (audience_uris(activity) ++
       audience_uris(object) ++
       [activity["object"], object["object"], object["actor"], object["inReplyTo"]])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(@inbox_addressed_cap)
    |> Enum.flat_map(&local_actor_ref/1)
    |> Enum.uniq()
    |> actors_by_ref()
  end

  # Which of our own actors a URI names, as `{kind, handle}` — resolved as a
  # reference first and loaded in one query per kind below, so a delivery naming
  # twenty URLs still costs three lookups rather than twenty.
  defp local_actor_ref(uri) do
    case local_path(uri) do
      nil -> tag_actor_ref(uri)
      segments -> ref_from_segments(segments)
    end
  end

  # A page's URLs first: they are the more specific shape, and the member clauses
  # below would otherwise read `/organizations/acme/actor` as the member
  # `organizations` (a word `Vutuv.Accounts.ReservedSlugs` keeps unclaimable, so
  # the lookup would miss — but a rule that holds by luck is not a rule).
  defp ref_from_segments(["organizations", slug, "actor" | _]),
    do: [{:organization, String.downcase(slug)}]

  defp ref_from_segments(["organizations", slug, "posts", _id | _]),
    do: [{:organization, String.downcase(slug)}]

  defp ref_from_segments([username, "actor" | _]), do: [{:user, String.downcase(username)}]
  defp ref_from_segments([username, "posts", _id | _]), do: [{:user, String.downcase(username)}]
  defp ref_from_segments(_segments), do: []

  # A topic's actor lives on its own host (`tags.<host>`), which is precisely why
  # `local_path/1` must not answer for it: `https://tags.<host>/hund` would come
  # back as the member `hund`. So the tag host is asked separately, and the slug
  # is the whole path — the actor id is `#{tag_base()}/<slug>`.
  defp tag_actor_ref(uri) do
    with true <- tag_host?(uri),
         %URI{path: path} <- URI.parse(uri),
         [slug | _rest] <- String.split(path || "", "/", trim: true) do
      [{:tag, String.downcase(slug)}]
    else
      _ -> []
    end
  end

  # One query per kind for the whole addressee list, not one per URI. A merged
  # alias is left out of the topic lookup (`merged_into_id`): an alias is another
  # name for a topic, never a second actor, so a delivery to one is a delivery to
  # nothing — the same answer `with_federated_tag` gives at the topic's own inbox.
  defp actors_by_ref(refs) do
    users_by_username(for {:user, name} <- refs, do: name) ++
      organizations_by_slug(for {:organization, slug} <- refs, do: slug) ++
      tags_by_slug(for {:tag, slug} <- refs, do: slug)
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

  defp users_by_username([]), do: []

  defp users_by_username(usernames),
    do: Repo.all(from(u in User, where: u.username in ^usernames))

  defp organizations_by_slug([]), do: []

  defp organizations_by_slug(slugs),
    do: Repo.all(from(o in Organization, where: o.slug in ^slugs))

  defp tags_by_slug([]), do: []

  defp tags_by_slug(slugs),
    do: Repo.all(from(t in Tag, where: t.slug in ^slugs and is_nil(t.merged_into_id)))

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

  @doc """
  A favourite or re-share of a **page's** post, from another network (issue
  #1334 completing #1068 for pages).

  Without this a page publishes outward and learns nothing back: its post can
  travel and be re-shared and the team would see a flat zero. The counts need no
  work — `fediverse_reactions` hangs off the post, not off a member, so
  `Posts.shown_counts/1` folds a stored row in by itself. What was missing was
  only the way in.

  There is no per-page reactions switch to check. `users.fediverse_reactions?`
  lets a member federate without collecting strangers' reactions; a page that
  deliberately publishes outward has no comparable reason to want the traffic
  and not the tally, so it is not asked twice.
  """
  def record_organization_reaction(%Organization{} = page, object, kind, actor)
      when kind in ~w(like announce) do
    %{uri: actor_uri} = actor = actor_attrs(actor)

    with true <- enabled?(),
         true <- federated?(page),
         %Post{} = post <- resolve_own_note(page, object),
         :ok <- check_inbound_cap(actor_uri),
         {:ok, _reaction} <- insert_reaction(post, actor, kind) do
      Posts.broadcast_post_counters(post.id)
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
  Removes a reaction the remote side took back (`Undo(Like)` / `Undo(Announce)`)
  from a member's or a page's post. Honoured at once and unconditionally — an
  upstream withdrawal is the deletion path that makes storing the row
  defensible, so it must not depend on any switch still being on.
  """
  def remove_reaction(owner, object, kind, actor_uri) when kind in ~w(like announce) do
    with %Post{} = post <- resolve_own_note(owner, object) do
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

  # The post behind an activity's `object`, but only when it is a Note URL of
  # ours naming *this* member's or page's post — the ownership check is the
  # point: a Like naming somebody else's post must not be recorded against this
  # owner. One head per kind, because `Docs.note_url/2` mints two path shapes.
  # A member's note lives at `/:handle/posts/:id`; ownership is checked on the
  # row's own `user_id` and the handle segment stays unpinned — the id names
  # the post, and the handle beside it goes stale on a rename. A page's lives
  # under `/organizations/:slug/posts/:id`, whose slug segment is pinned.
  # `local_path/1` reads the URL, so the `www.`/`http` spellings count too
  # (issue #1211). A URL naming somebody else's post, a foreign host, or a
  # malformed id is a miss (nil), never a raise.
  defp resolve_own_note(%Organization{id: page_id, slug: slug}, object) do
    with uri when is_binary(uri) <- activity_object_id(object),
         ["organizations", ^slug, "posts", post_id] <- local_path(uri),
         %Post{organization_id: ^page_id} = post <-
           UUIDv7.with_cast(post_id, &Repo.get(Post, &1)) do
      post
    else
      _ -> nil
    end
  end

  defp resolve_own_note(user, object) do
    with uri when is_binary(uri) <- activity_object_id(object),
         [_username, "posts", post_id] <- local_path(uri),
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
  A reply from another network under a **page's** post (issue #1334, completing
  #1069 for pages).

  `insert_note/5` needed no change: a note hangs off the post, and the audience
  it records is decided through `Docs.actor_url/1`, which knows both kinds. What
  is missing on the member version is deliberate — no `fediverse_replies?`
  switch (a page that publishes outward has no comparable reason to want the
  traffic and not the answers), no `restricted?` check (an organization post
  carries no audience by construction), and no per-member notification, because
  a page's news reaches its team through its own activity list.
  """
  def record_organization_reply(%Organization{} = page, activity, actor) do
    with true <- enabled?(),
         true <- federated?(page),
         %{} = object <- note_object(activity["object"]),
         %Post{} = post <- resolve_own_note(page, object["inReplyTo"]),
         :ok <- check_inbound_cap(actor.uri),
         {:ok, _note} <- insert_note(page, post, activity, object, actor) do
      Posts.broadcast_post_counters(post.id)
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
         text when text != "" <-
           remote_text(object["content"], Note.max_content(), object["tag"]) do
      note
      |> Note.changeset(%{
        content_text: text,
        summary: remote_text(object["summary"], Note.max_summary()),
        language: as2_language(object),
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
  The DOM anchor of one stored remote reply, e.g.
  `"fediverse-reply-019fb8b5-cb56-765a-99c3-82aea0498272"`.

  A remote reply has no permalink of its own here — it is rendered inside the
  conversation under the post it answers — so the way to send a reader to one
  is the post's permalink plus this fragment. Both ends live in one function
  because they have to agree exactly: the card that carries it as its `id`
  (`VutuvWeb.PostComponents.remote_reply_card/1`) and the notification quote
  that links to it. A drift between them is silent, since a fragment that
  matches nothing simply opens the page at the top.
  """
  def reply_anchor(note_id) when is_binary(note_id), do: "fediverse-reply-" <> note_id

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

  @doc """
  The same replies as `list_notes/2`, capped at the newest `:per_post` of each
  post — what the **feed** weaves into its threads, where the permalink shows
  every one.

  The cap is what keeps a post that went round out there from taking over a
  timeline: a conversation with forty answers is a page to open, not a row to
  scroll past. `:keep` names ids the cap must not drop — a note that one of the
  page's own posts answers, which would otherwise leave that answer hanging
  under nothing — and it is applied **inside** the visibility scope, so a
  private note stays private even when its answer is on the page.
  """
  def list_feed_notes(post_ids, viewer, opts \\ [])

  def list_feed_notes([], _viewer, _opts), do: %{}

  def list_feed_notes(post_ids, viewer, opts) do
    if enabled?() do
      per_post = Keyword.get(opts, :per_post, 3)
      keep = Keyword.get(opts, :keep, [])

      ranked =
        from(n in Note,
          join: p in Post,
          on: p.id == n.post_id,
          where: n.post_id in ^post_ids,
          where: n.audience == "public" or p.user_id == ^note_viewer_id(viewer),
          select: %{
            id: n.id,
            rank:
              over(row_number(),
                partition_by: n.post_id,
                order_by: [desc: n.received_at, desc: n.id]
              )
          }
        )

      wanted =
        from(r in subquery(ranked), where: r.rank <= ^per_post or r.id in ^keep, select: r.id)

      from(n in notes_with_account(),
        where: n.id in subquery(wanted),
        order_by: [asc: n.received_at, asc: n.id]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.post_id)
    else
      %{}
    end
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
  Whoever may act as the post's author takes a reply off it. Deletes it at once
  and records the takedown in `Vutuv.Fediverse.NoteEvent`.

  For an **organization** post that is every current publisher of the page, the
  same rule `Posts.author?/2` applies to editing it — and for a page this is the
  *only* lever there is, since a page has no replies switch to turn the whole
  stream off the way a member does (`users.fediverse_replies?`).

  Nothing leaves the building: removing a reply from your own post is a decision
  about *your* page, not an accusation, so the origin server is not told. Saying
  "this is not appropriate" is `report_note/2`, which does tell them.
  """
  def remove_note(note_id, %User{} = actor) do
    with {:ok, _note, _post} <-
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
        with {:ok, note, post} <-
               take_down_note(note_id, reporter, "reported", &note_visible?/3) do
          flag_note(note, post, reporter)
          :ok
        end

      _ ->
        {:error, :rate_limited}
    end
  end

  # Files the report with the server the reply came from (issue #1102).
  #
  # Signed by the **author of the post the reply sat under** — a member or a
  # page — never by the reporter. A `Flag` is a signed statement, so it has to
  # come from an actor we serve a key for, and vutuv has no installation-wide
  # actor to file from (Mastodon uses its instance actor for exactly this). The
  # thread's owner is the party that server already knows in this conversation,
  # and using them keeps a bystander reporter out of a message that travels to
  # strangers: nothing in the `Flag` names who reported it, and no content rides
  # along — the reported object's own id is the whole reference.
  #
  # `Posts.author/1` is what makes the page case work at all. Reading the signer
  # off `posts.user_id` handed `Repo.get(User, nil)` a NULL for an organization
  # post, which RAISES rather than answering nothing: a 500 on the report button
  # under every page post, and behind a gate (the note needs an inbox) that no
  # member-side test could reach.
  #
  # Skipped when the note carried no answerable inbox (`own_inbox/1` refuses an
  # inbox on a host the actor does not control), when the post's author never
  # federated (no key to sign with), or when the operator has blocked that server
  # — a block is both ears and mouth shut.
  defp flag_note(%Note{} = note, %Post{} = post, %User{} = reporter) do
    with inbox when is_binary(inbox) <- note.inbox_uri,
         author when not is_nil(author) <- Posts.author(post),
         true <- ever_federated?(author),
         false <- instance_blocked?(note.actor_uri) do
      enqueue(author, [inbox], Docs.flag_activity(author, note.object_uri, note.actor_uri))
      log_note_event(note, post, reporter, "flagged")
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

    due =
      schema
      |> where([r], r.expires_at <= ^now)
      |> spare_reposted(schema)

    # A cached post takes its pictures' files with it (issue #1163); a reply has
    # none, so this is a no-op for the other caller.
    if schema == RemotePost, do: wipe_media(due)

    {count, _} = Repo.delete_all(due)
    count
  end

  # A cached post somebody here reposted outlives the ceiling (issue #1166): the
  # repost is a standing claim that this is worth showing, and pulling it out
  # from under the people reading it on a calendar rule would be the wrong call.
  # What keeps that honest is not this exemption but `refresh_reposted_posts/0`,
  # which asks the origin and deletes the moment the original is gone.
  defp spare_reposted(query, RemotePost) do
    # Only while the verification is **current**. The exemption is a promise
    # that this copy is still wanted *and* still published, and the second half
    # is only true as long as somebody keeps asking. A member may reshare far
    # faster than one sweep can re-check (the budget allows 100 an hour, a run
    # checks a bounded batch), so an exemption that never expired would let one
    # account pin an unbounded pile of third-party content here forever,
    # unverified — the exact opposite of the bargain. Falling out of the
    # exemption when the check falls behind makes the failure mode "expires
    # like everything else" instead.
    stale = DateTime.add(DateTime.utc_now(:second), -@repost_recheck_stale_days * 86_400)

    reposted =
      from(r in PostRepost,
        where: r.remote_post_id == parent_as(:post).id,
        where: coalesce(parent_as(:post).checked_at, parent_as(:post).received_at) > ^stale
      )

    from(p in query, as: :post, where: not exists(reposted))
  end

  defp spare_reposted(query, _schema), do: query

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

  # What each remote server has stored here as replies, biggest first — the
  # other half of the operator's `/admin/fediverse` picture beside
  # `inbound_hosts/1`.
  defp note_hosts(limit) do
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

  # An activity delivers what it claims, or it is dropped: a Create whose object
  # is a bare id is not worth an outbound request to a stranger's server.
  defp note_object(%{"type" => "Note"} = object), do: object
  defp note_object(_), do: nil

  defp insert_note(user, post, activity, object, actor) do
    uri = object["id"]
    text = remote_text(object["content"], Note.max_content(), object["tag"])
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
          origin_url: SearchText.normalize_search(object["url"]),
          in_reply_to_uri: object["inReplyTo"],
          inbox_uri: own_inbox(actor),
          handle: actor.handle,
          display_name: actor.name,
          content_text: text,
          summary: remote_text(object["summary"], Note.max_summary()),
          language: as2_language(object),
          audience: audience(user, activity, object),
          received_at: received,
          # It was demonstrably published the moment it was delivered, so the
          # delivery is the first freshness confirmation.
          checked_at: received,
          expires_at: DateTime.add(received, note_retention_days() * 86_400)
        })
        |> put_object_counts(object)
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

  @doc """
  Whether `b` is an `https` URL on the same host as `a` — the anti-spoofing
  predicate behind "an actor only speaks for its own host": an inbox, a keyId
  or any other URL a remote document names for itself must live on the host of
  the actor naming it, or an attacker-controlled host could serve documents
  claiming somebody else's identity. The `https` pin sits on `b`, the URL that
  gets fetched or delivered to.
  """
  def same_host?(a, b) when is_binary(a) and is_binary(b) do
    case {URI.parse(a), URI.parse(b)} do
      {%URI{host: host}, %URI{host: host, scheme: "https"}} when is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  def same_host?(_a, _b), do: false

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

  # `tags` is the object's AP `tag` array: content passes it so a bare `@user`
  # mention widens to the linkable `@user@host` (see `Vutuv.RemoteHtml`); a
  # summary is a content warning and stays as written.
  defp remote_text(html, max, tags \\ [])

  defp remote_text(nil, _max, _tags), do: nil

  defp remote_text(html, max, tags) when is_binary(html),
    do: SearchText.normalize_search(RemoteHtml.to_text(html, max, tags))

  defp remote_text(_html, _max, _tags), do: nil

  # The nil UUID can never match a row: "not the author" without a NULL arm,
  # the same trick `Vutuv.Posts.engagement_viewer_id/1` uses.
  defp note_viewer_id(%User{id: id}), do: id
  defp note_viewer_id(id) when is_binary(id), do: id
  defp note_viewer_id(_), do: "00000000-0000-0000-0000-000000000000"

  # Whoever may act as the post's author may take a reply off it (or an admin).
  # `Posts.author?/2` is the one predicate for that, which is what widens this
  # to a page's publishers: an organization post leaves `posts.user_id` NULL, so
  # comparing ids here used to answer false for everybody but an admin, and a
  # page's team had no lever at all over what strangers wrote under its posts.
  defp note_owner?(_note, %Post{} = post, %User{} = actor),
    do: Posts.author?(post, actor) or actor.admin? == true

  # Anyone who can see it may report it, which for a private reply is its
  # addressee alone.
  defp note_visible?(note, %Post{} = post, %User{} = actor),
    do: Note.public?(note) or note_owner?(note, post, actor)

  defp take_down_note(note_id, %User{} = actor, action, authorized?) do
    query =
      from(n in Note,
        join: p in Post,
        on: p.id == n.post_id,
        where: n.id == ^to_string(note_id),
        select: {n, p}
      )

    case UUIDv7.with_cast(note_id, fn _ -> Repo.one(query) end) do
      {%Note{} = note, %Post{} = post} ->
        if authorized?.(note, post, actor) do
          Repo.delete(note)
          log_note_event(note, post, actor, action)
          Posts.broadcast_post_counters(note.post_id)
          # The deleted row is handed back so the caller can still address the
          # origin server (`flag_note/3`) — after this it is the only copy of
          # that address left. The post rides along because the `Flag` has to be
          # signed by its author, whichever kind of author that is.
          {:ok, note, post}
        else
          {:error, :not_allowed}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp log_note_event(%Note{} = note, %Post{} = post, %User{} = actor, action) do
    log_takedown(%{
      action: action,
      host: Note.host(note.actor_uri) || "unknown",
      actor_uri: note.actor_uri,
      audience: note.audience,
      user_id: post.user_id,
      organization_id: post.organization_id,
      actor_id: actor.id
    })
  end

  # The one writer of the content-free takedown ledger, so its field set — and
  # the keyed digest that stands in for the actor — has a single definition
  # whatever kind of cached content was taken down. `user_id` /
  # `organization_id` is whose page it sat on — exactly one of them for a reply
  # under a post — and both are absent for content that sat on nobody's (a
  # cached post from a followed account, issue #1161).
  defp log_takedown(attrs) do
    Repo.insert!(%NoteEvent{
      action: attrs.action,
      host: attrs.host,
      actor_digest: note_actor_digest(attrs.actor_uri),
      audience: attrs.audience,
      user_id: attrs[:user_id],
      organization_id: attrs[:organization_id],
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
    text = remote_text(doc["content"], Note.max_content(), doc["tag"])
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
  #
  # The freshness check has no use for the ETag, so it drops it and keeps the
  # two-element shape its three call sites already match on.
  defp fetch_remote_note(uri, signer) do
    case fetch_object(uri, signer, nil) do
      {:ok, doc, _etag} -> {:ok, doc}
      other -> other
    end
  end

  # The same fetch, conditional: with `etag` in hand it sends `If-None-Match`
  # and a `304` costs both sides an empty body (issue #1283). Answers
  # `{:ok, doc, etag}`, `{:not_modified, etag}`, `{:gone, status}` or
  # `{:error, reason}`.
  defp fetch_object(uri, signer, etag) do
    with {:parse, %URI{scheme: "https", host: host}} <- {:parse, URI.parse(uri)},
         {:ssrf, false} <- {:ssrf, Vutuv.Ssrf.resolves_to_internal?(host)},
         {:ok, %Req.Response{} = response} <- ap_get(uri, signer, etag) do
      read_object(response)
    else
      other -> {:error, other}
    end
  end

  defp read_object(%Req.Response{status: 304} = response),
    do: {:not_modified, response_etag(response)}

  defp read_object(%Req.Response{status: 200, body: body} = response) do
    with {:size, true} <- {:size, is_binary(body) and byte_size(body) <= @max_body_bytes},
         {:ok, %{} = doc} <- Jason.decode(body) do
      {:ok, doc, response_etag(response)}
    else
      other -> {:error, other}
    end
  end

  defp read_object(%Req.Response{status: status}) when status in [403, 404, 410],
    do: {:gone, status}

  defp read_object(%Req.Response{status: status}), do: {:error, {:http, status}}

  defp response_etag(%Req.Response{} = response) do
    case Req.Response.get_header(response, "etag") do
      [etag | _rest] when is_binary(etag) -> etag
      _none -> nil
    end
  end

  ## Keeping a reposted copy honest (issue #1166)

  @doc """
  Asks the origin of every reposted cached post that is due whether it is still
  published, and acts on the answer.

  This is what makes the retention exemption above defensible. A repost holds a
  copy past its six-month ceiling, so something has to keep asking whether it
  should still be here at all — a cache nobody re-checks is just a copy.

  `200` and still open pushes the ceiling out and re-stamps `checked_at`; `404`,
  `410` and `403` delete the copy **and its reposts**, because a repost must
  never keep alive what its author has already deleted or locked away. Anything
  else changes nothing: a server that stays offline cannot buy indefinite
  retention, and its outage cannot trigger a mass delete either.

  Bounded per run like every other outbound sweep here.
  """
  def refresh_reposted_posts(limit \\ 20) do
    if enabled?() do
      limit |> due_reposted_posts() |> Enum.map(&refresh_reposted_post/1) |> refresh_tally()
    else
      %{refreshed: 0, deleted: 0, skipped: 0}
    end
  end

  @doc "One reposted cached post, verified against its origin. See `refresh_reposted_posts/1`."
  def refresh_reposted_post(%RemotePost{} = post) do
    if enabled?() do
      with %User{} = reposter <- any_reposter(post),
           # An unsigned GET is not a question this can act on: an
           # authorized-fetch server answers it 403, which `fetch_remote_note/2`
           # reads as "gone" — and that would delete a perfectly live public post
           # plus everybody's reshares of it, on nothing but our own missing key.
           signer when not is_nil(signer) <- signer(reposter) do
        apply_repost_refresh(post, fetch_remote_note(post.object_uri, signer))
      else
        _ ->
          stamp_repost_check(post)
          :skip
      end
    else
      :skip
    end
  end

  defp due_reposted_posts(limit) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@repost_recheck_days * 86_400)

    Repo.all(
      from(p in RemotePost,
        join: r in PostRepost,
        on: r.remote_post_id == p.id,
        where: is_nil(p.checked_at) or p.checked_at <= ^cutoff,
        distinct: true,
        # Nulls first: a freshly reshared copy has never been verified at all,
        # which is the least-known state and the one whose exemption just
        # began. Postgres sorts NULLs last on ASC, so it would otherwise queue
        # behind every row we already know about.
        order_by: [asc_nulls_first: p.checked_at, asc: p.id],
        limit: ^limit,
        preload: [:remote_account]
      )
    )
  end

  # Signed as one of the members who reposted it: the fetch has to carry an
  # actor key for authorized-fetch servers, and a reposter is by definition
  # somebody with a standing interest in this post still being here.
  defp any_reposter(%RemotePost{id: id}) do
    Repo.one(
      from(r in PostRepost,
        join: u in User,
        on: u.id == r.user_id,
        where: r.remote_post_id == ^id,
        order_by: [asc: r.id],
        limit: 1,
        select: u
      )
    )
  end

  defp apply_repost_refresh(%RemotePost{} = post, {:ok, doc}) do
    text = remote_text(doc["content"], RemotePost.max_content(), doc["tag"])

    cond do
      not doc_public?(doc) ->
        narrowed_upstream(post)

      # The author emptied it. The same "stop showing this" a narrowing carries,
      # and the reply refresh beside this makes the same call.
      text in [nil, ""] and picture_only_doc?(doc) == false ->
        narrowed_upstream(post)

      true ->
        now = DateTime.utc_now(:second)

        # The re-fetched text is applied, not discarded. For exactly the
        # population this exemption keeps alive, an `Update` may never arrive —
        # nobody here need follow the author any more — so this is the only
        # channel through which an author's correction reaches our copy.
        post
        |> RemotePost.changeset(%{
          content_text: text || post.content_text,
          summary: remote_text(doc["summary"], RemotePost.max_summary())
        })
        |> Ecto.Changeset.put_change(:checked_at, now)
        |> Ecto.Changeset.put_change(
          :expires_at,
          DateTime.add(now, remote_post_retention_days() * 86_400)
        )
        |> Repo.update()
        |> case do
          {:ok, _} -> :refreshed
          {:error, _} -> :skip
        end
    end
  end

  defp apply_repost_refresh(%RemotePost{} = post, {:gone, status}) do
    Logger.info("fediverse cached post #{post.id} gone upstream (#{status}), deleting")
    delete_cached_post(post)
    :deleted
  end

  defp apply_repost_refresh(%RemotePost{} = post, _other) do
    stamp_repost_check(post)
    :skip
  end

  # The scheduler's clock, not a claim that the origin was reached. Without it a
  # copy nobody can sign for — or whose server is down — stays due on every run,
  # and since `due_reposted_posts/1` serves the least recently checked first it
  # holds the front of every batch from then on, spending the cap on work that
  # cannot complete while genuinely due copies behind it are never re-verified.
  # No strike: the origin did nothing wrong, and a signer can appear the moment
  # somebody who federates reshares the same post. See `refresh_counts/1`, which
  # carries the long version of this lesson.
  defp stamp_repost_check(%RemotePost{id: id}) do
    Repo.update_all(from(p in RemotePost, where: p.id == ^id),
      set: [checked_at: DateTime.utc_now(:second)]
    )
  end

  defp picture_only_doc?(doc),
    do: doc["attachment"] |> List.wrap() |> Enum.any?(&Media.image_attachment?/1)

  defp narrowed_upstream(%RemotePost{} = post) do
    # The author narrowed or emptied it: the same "stop showing this" a 403
    # carries, and a boost of it must stop too.
    delete_cached_post(post)
    :deleted
  end

  defp refresh_tally(results) do
    %{
      refreshed: Enum.count(results, &(&1 == :refreshed)),
      deleted: Enum.count(results, &(&1 == :deleted)),
      skipped: Enum.count(results, &(&1 not in [:refreshed, :deleted]))
    }
  end

  ## The origin's own figures (issue #1283)
  ##
  ## How many people liked a post out there, and how many passed it on. Nothing
  ## about a third party's counters is ever delivered here — a `Like` goes to
  ## the author's inbox and an `Announce` to the author plus the announcer's
  ## followers — so for somebody else's post the only route is to ask the object
  ## itself, where ActivityPub §5.7/§5.8 put `likes` and `shares`.
  ##
  ## Which makes the whole design about **not** being a bad neighbour: a
  ## background ladder that asks often while a post is new and stops entirely
  ## once it is a week old, a conditional GET, a per-host and a per-run cap, and
  ## a backoff that takes a struggling server off the list. Never on a page
  ## render, which would make a popular thread an amplifier.

  # Consecutive failures after which an object leaves the ladder for good. Four
  # asks spread by the doubling backoff below is well over a day of trying.
  @counts_max_strikes 4

  # A hostile `totalItems` must not reach an `integer` column (22003 on the
  # refresh path, which nothing user-facing guards). Far above any real tally.
  @counts_max_total 1_000_000_000

  # An ETag is a stranger's string in a `text` column. Kept short anyway: it is
  # sent back on every ask, and a server that answers with a megabyte of header
  # has said nothing useful.
  @counts_etag_max 512

  @counts_topic "fediverse:counts"

  @doc "Whether the background counts refresher runs at all on this installation."
  def counts_refresh_enabled?, do: Application.get_env(:vutuv, :fediverse_counts, true)

  @doc """
  The re-ask ladder as `{age in minutes, interval in minutes}` pairs, youngest
  tier first. Past the last tier nothing is asked again.
  """
  def counts_ladder, do: Application.get_env(:vutuv, :fediverse_counts_ladder, [])

  @doc "How many objects one refresh run may ask about."
  def counts_batch, do: Application.get_env(:vutuv, :fediverse_counts_batch, 60)

  @doc "How many of those may belong to any one host."
  def counts_per_host, do: Application.get_env(:vutuv, :fediverse_counts_per_host, 10)

  @doc "How many failed asks in a row drop an object off the ladder."
  def counts_max_strikes, do: @counts_max_strikes

  @doc """
  The topic every open page listens on for a changed figure.

  **One** topic rather than one per object: a run changes a handful of numbers
  and each listener keeps only the cards it is showing, which is far cheaper
  than a subscription per rendered card on a feed page.
  """
  def counts_topic, do: @counts_topic

  @doc "Listen for changed figures. See `counts_topic/0`."
  def subscribe_counts, do: Phoenix.PubSub.subscribe(Vutuv.PubSub, @counts_topic)

  @doc """
  What the origin last said about this object, as `%{likes:, shares:}`.

  Either may be `nil`, and `nil` is **not** zero: both collections are MAY in
  the spec and some software serves neither, so "we have not been told" has to
  stay distinguishable from "nobody liked it". The bar renders nothing for a
  `nil`; a `0` would be a claim we cannot make.
  """
  def counts(%RemotePost{} = post), do: %{likes: post.likes_count, shares: post.shares_count}
  def counts(%Note{} = note), do: %{likes: note.likes_count, shares: note.shares_count}

  @doc """
  Asks the origins of every due object for their own figures, bounded per run
  and per host. Returns `%{updated:, unchanged:, failed:, skipped:}`.

  Sequential on purpose: this is the one sweep whose whole point is being quiet,
  and a bounded batch of conditional GETs run one after another is both quiet
  and simple — no task supervision, and a test can call it inside the SQL
  sandbox.
  """
  def refresh_due_counts do
    if enabled?() do
      counts_batch() |> due_for_counts() |> Enum.map(&refresh_counts/1) |> counts_tally()
    else
      %{updated: 0, unchanged: 0, failed: 0, skipped: 0}
    end
  end

  @doc """
  The objects whose origin is due to be asked again, least recently asked first
  and capped at `counts_per_host/0` per host.

  Due-ness is the ladder in `counts_ladder/0` applied to the object's **own**
  age, times the doubling backoff of its failed asks. An object past the last
  tier is never due again: its tally has stopped moving, and asking would be
  traffic a stranger's server pays for and nobody reads.
  """
  def due_for_counts(limit) do
    now = DateTime.utc_now(:second)
    ladder = counts_ladder()

    posts = Repo.all(due_counts_query(RemotePost, :published_at, now, ladder, limit))
    notes = Repo.all(due_counts_query(Note, :received_at, now, ladder, limit))

    (posts ++ notes)
    |> Enum.sort_by(&counts_order/1)
    |> cap_per_host(counts_per_host())
    |> Enum.take(limit)
  end

  # The two tables' own orders merged into one, and it has to agree with the
  # `order_by` each of them was fetched under or the merge would undo it.
  #
  # **Not** the `DateTime` struct itself: Erlang's term order compares maps field
  # by field in key order, so it would weigh `day` before `month` and `year` and
  # sort the queue by nothing anybody means.
  defp counts_order(%{counts_checked_at: nil} = subject),
    do: {0, -DateTime.to_unix(counts_age(subject)), subject.id}

  defp counts_order(subject),
    do: {1, DateTime.to_unix(subject.counts_checked_at), subject.id}

  # How old the thing itself is — the clock the ladder runs on. A cached post
  # was published somewhere; a reply was delivered here, which is the closest
  # thing it has to the same fact.
  defp counts_age(%RemotePost{published_at: at}), do: at
  defp counts_age(%Note{received_at: at}), do: at

  @doc """
  Asks one object's origin for its figures and stores the answer.

  `:updated` when a number moved (and every open page has been told), `:unchanged`
  for a `304` or an identical answer, `:failed` for a strike, `:skip` when the
  question cannot honestly be asked at all.

  Three things it deliberately does **not** do:

    * **Ask about anything but a public or unlisted object.** A followers-only
      or direct object answers `403`, and asking would tell its origin that we
      hold their member's private post and how often we look at it.
    * **Ask unsigned.** With no member keypair behind the object there is
      nobody to sign as, and an authorized-fetch server's `403` would then be a
      statement about us, not about the object.
    * **Delete anything.** A `404` here is a strike, not a takedown: deletion
      belongs to the retention paths (`refresh_note/1`,
      `refresh_reposted_post/1`), which are built to weigh a `403` properly.
      A counter refresh must never become a deletion path by accident.

  A `:skip` still stamps `counts_checked_at`, and that is the one thing here
  worth spelling out. It is not a claim that we asked: it is the ladder's clock,
  and leaving it alone means the object is due again on the next run — for good,
  since nothing about it changes in two minutes — while `due_for_counts/1`
  serves the least recently asked first and therefore puts it at the head of
  every queue from now on. A handful of such objects then spend the whole batch
  cap on questions nobody can ask, and the posts a member is reading right now,
  stamped on arrival and so last in the queue, are never reached at all. That
  ran on production: every object boosted into the feed by a followed account
  was unsignable (fixed in `counts_signer/1` below), 50 of them held the front
  of a 60-object batch, and the day's posts kept the `0` their `Create` had
  carried. Stamped, the object simply rejoins the ladder, is reconsidered at
  its tier's pace, and ages off it like everything else — no strike, because
  the origin did nothing wrong and a signer can appear the moment somebody here
  follows the account.
  """
  def refresh_counts(subject) do
    if enabled?(), do: ask_counts(subject), else: :skip
  end

  defp ask_counts(subject) do
    with true <- counts_askable?(subject),
         signer when not is_nil(signer) <- counts_signer(subject) do
      apply_counts(subject, fetch_object(subject.object_uri, signer, subject.counts_etag))
    else
      _ ->
        stamp_counts(subject, [])
        :skip
    end
  end

  # Public and unlisted only — see `refresh_counts/1`.
  defp counts_askable?(%RemotePost{} = post), do: RemotePost.open?(post)
  defp counts_askable?(%Note{} = note), do: Note.public?(note)

  # Somebody here with a keypair who has a reason to be asking: for a cached
  # post any member who follows the account, for a reply the member whose post
  # it answers.
  #
  # A boosted post has neither, and it is not a rare case — a large share of
  # what any account contributes is boosts, and their authors live on servers
  # nobody here follows. The reason to ask is one step further out: a member
  # follows the account that re-shared it, which is why the post is in their
  # feed and why its card carries these figures at all. That is also exactly
  # who `fetch_and_store_announced/2` signed as to store the post in the first
  # place, so the fallback claims nothing new about us.
  defp counts_signer(%RemotePost{} = post) do
    case account_follower(post.remote_account_id) || boost_follower(post) do
      %User{} = follower -> signer(follower)
      nil -> nil
    end
  end

  defp counts_signer(%Note{} = note) do
    with %Post{} = post <- Repo.get(Post, note.post_id),
         %User{} = author <- Repo.get(User, post.user_id) do
      signer(author)
    else
      _ -> nil
    end
  end

  # A member who follows the account and holds a keypair. `nil` in rather than
  # a query on it: `where: f.remote_account_id == ^nil` raises, it is not a
  # silent no-op.
  defp account_follower(nil), do: nil

  defp account_follower(account_id) do
    Repo.one(
      from(f in Follow,
        join: u in User,
        on: u.id == f.user_id,
        join: a in Actor,
        on: a.user_id == u.id,
        where: f.remote_account_id == ^account_id,
        order_by: [asc: f.id],
        limit: 1,
        select: u
      )
    )
  end

  # The same, for whoever re-shared the post into somebody's feed.
  defp boost_follower(%RemotePost{id: post_id}) do
    Repo.one(
      from(b in PostBoost,
        join: f in Follow,
        on: f.remote_account_id == b.remote_account_id,
        join: u in User,
        on: u.id == f.user_id,
        join: a in Actor,
        on: a.user_id == u.id,
        where: b.remote_post_id == ^post_id,
        order_by: [asc: f.id],
        limit: 1,
        select: u
      )
    )
  end

  defp apply_counts(subject, {:ok, doc, etag}) do
    store_counts(subject, %{
      likes_count: collection_total(doc["likes"]),
      shares_count: collection_total(doc["shares"]),
      counts_etag: truncate_etag(etag)
    })
  end

  # The figures live in the body, so a `304` really does mean "nothing changed"
  # — which is the whole reason the conditional GET is worth sending.
  defp apply_counts(subject, {:not_modified, etag}),
    do: store_counts(subject, %{counts_etag: truncate_etag(etag)})

  # Unreachable, a 429, a 5xx, a 404, a body we cannot read: a strike, and the
  # next ask is twice as far away. Nothing about the stored figures changes.
  defp apply_counts(subject, _other) do
    stamp_counts(subject, counts_failures: subject.counts_failures + 1)
    :failed
  end

  # A `nil` is never written over a figure we already hold: it means the server
  # did not tell us this time, not that the number dropped to zero.
  defp store_counts(subject, attrs) do
    sets = attrs |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Keyword.new()
    updated = struct(subject, sets)

    case stamp_counts(subject, sets ++ [counts_failures: 0]) do
      0 ->
        :skip

      _ ->
        if counts(updated) == counts(subject) do
          :unchanged
        else
          broadcast_counts(updated)
          :updated
        end
    end
  end

  # By id rather than through the struct in hand: the retention sweep can delete
  # the row while this run is in flight, and `Repo.update/1` would then raise
  # `Ecto.StaleEntryError` inside the refresher. A vanished row is simply no
  # rows updated.
  defp stamp_counts(subject, sets) do
    sets = Keyword.put(sets, :counts_checked_at, DateTime.utc_now(:second))

    {count, _} =
      Repo.update_all(from(r in subject_schema(subject), where: r.id == ^subject.id), set: sets)

    count
  end

  defp broadcast_counts(subject) do
    Phoenix.PubSub.broadcast(
      Vutuv.PubSub,
      @counts_topic,
      {:fediverse_counts, subject_kind(subject), subject.id, counts(subject)}
    )
  end

  @doc """
  Which kind of thing from another network this is — the word the action bar
  and the broadcast use so one message can name either.
  """
  def subject_kind(%RemotePost{}), do: :remote_post
  def subject_kind(%Note{}), do: :note

  @doc """
  What makes two cards **the same card**: `{kind, id}` for a thing from another
  network.

  This is the identity `VutuvWeb.PostLive.RemoteActionsComponent.dom_id/2` is
  built from, and therefore the only key a page may dedupe its cards by. The two
  have to be the same question, because the bar is a LiveComponent keyed by it:
  a page that renders two cards for one subject emits one LiveView id twice,
  which raises inside `render_pending_components/6` during the **static** render
  — the page 500s rather than degrading.

  That is not hypothetical. `/feed` went down on 2026-08-28 (v7.422.1) because
  `Vutuv.Posts.attach_remote_parents/3` deduped its batch reads by
  `remote_post.id` and then placed the cards from a list keyed by `post_id`, so
  two member posts answering one cached post each drew the parent. The rule was
  written in prose beside three sibling implementations and broken by the fourth
  in the very commit that wrote it down. Prose beside an implementation is not
  an invariant; one function every site keys on is.

  So: whenever a page decides how many cards a subject gets — `dedupe_remote/1`,
  `attach_thread_notes/3`, `attach_remote_parents/3`, and whatever comes next —
  dedupe on this, not on a field picked by hand. A `grep` for it finds every
  site that owes the rule.
  """
  def subject_key(subject), do: {subject_kind(subject), subject.id}

  defp subject_schema(%RemotePost{}), do: RemotePost
  defp subject_schema(%Note{}), do: Note

  # `totalItems` is whatever the origin claims — the same trust the post's text
  # already gets — but it lands in an `integer` column, so it is bounded here.
  defp collection_total(%{"totalItems" => total}) when is_integer(total) and total >= 0,
    do: min(total, @counts_max_total)

  defp collection_total(_absent), do: nil

  defp truncate_etag(etag) when is_binary(etag), do: String.slice(etag, 0, @counts_etag_max)
  defp truncate_etag(_none), do: nil

  defp counts_tally(results) do
    %{
      updated: Enum.count(results, &(&1 == :updated)),
      unchanged: Enum.count(results, &(&1 == :unchanged)),
      failed: Enum.count(results, &(&1 == :failed)),
      skipped: Enum.count(results, &(&1 == :skip))
    }
  end

  # One host may fill at most `per_host` of a run, so an instance that happens
  # to host many of the accounts our members follow is spread over several runs
  # rather than fetched in a burst. What that drops is logged rather than
  # silently swallowed — a cap nobody can see reads as "we asked about
  # everything".
  defp cap_per_host(subjects, per_host) do
    {kept, _seen} =
      Enum.reduce(subjects, {[], %{}}, fn subject, {kept, seen} ->
        host = object_host(subject)
        taken = Map.get(seen, host, 0)

        if taken < per_host,
          do: {[subject | kept], Map.put(seen, host, taken + 1)},
          else: {kept, seen}
      end)

    dropped = length(subjects) - length(kept)

    if dropped > 0 do
      Logger.info("Fediverse counts: #{dropped} due object(s) held back by the per-host cap")
    end

    Enum.reverse(kept)
  end

  defp object_host(subject), do: URI.parse(subject.object_uri).host

  # The ladder as one query per table: an object is due when its age falls in a
  # tier and its last ask is older than that tier's interval — doubled once per
  # failed ask, so a server having a bad day is asked less and less rather than
  # every five minutes. An object with `@counts_max_strikes` strikes has left
  # the ladder for good.
  # Least recently asked first — and, among the never-asked, **newest first**.
  # That tiebreaker is load-bearing rather than tidy: every row an installation
  # already holds when this ships has a null here, so the queue starts as one
  # long backfill, and ordering it by id (creation order, since the ids are v7)
  # would serve the six-month-old cache first and leave today's posts — the ones
  # somebody is actually reading — until last. Newest first means a post reaches
  # its figures within a run of arriving, and the old cache fills in behind it.
  defp due_counts_query(schema, age_field, now, ladder, limit) do
    from(r in schema,
      where: r.counts_failures < @counts_max_strikes,
      order_by: [
        asc_nulls_first: r.counts_checked_at,
        desc: field(r, ^age_field),
        asc: r.id
      ],
      limit: ^limit
    )
    |> where(^ladder_conditions(age_field, now, ladder))
  end

  # An object nobody has ever asked about is due **once**, whatever its age.
  # Without this, everything already cached when the feature shipped — and
  # everything an installation caches from a server that serves no collection in
  # its `Create` — would fall past the last tier before its first ask and carry
  # no figure for the rest of its six months. One ask each, and the ladder takes
  # over from there (an old post is stamped and never asked again). The batch and
  # per-host caps are what keep that backlog a trickle rather than a stampede.
  defp ladder_conditions(age_field, now, ladder) do
    {conditions, _younger_than} =
      Enum.reduce(ladder, {dynamic([r], is_nil(r.counts_checked_at)), nil}, fn {age_minutes,
                                                                                interval},
                                                                               {acc, younger} ->
        tier =
          dynamic(
            [r],
            ^age_window(age_field, now, age_minutes, younger) and
              (is_nil(r.counts_checked_at) or ^ask_due(interval, now))
          )

        {dynamic(^acc or ^tier), age_minutes}
      end)

    conditions
  end

  # The youngest tier has no upper edge, so a published stamp a minute in the
  # future (clock skew is ordinary between servers) still lands in it.
  defp age_window(age_field, now, age_minutes, nil),
    do: dynamic([r], field(r, ^age_field) > ^DateTime.add(now, -age_minutes * 60))

  defp age_window(age_field, now, age_minutes, younger) do
    dynamic(
      [r],
      field(r, ^age_field) > ^DateTime.add(now, -age_minutes * 60) and
        field(r, ^age_field) <= ^DateTime.add(now, -younger * 60)
    )
  end

  defp ask_due(interval, now) do
    dynamic(
      [r],
      fragment(
        "? <= ? - (? * power(2, ?) * interval '1 minute')",
        r.counts_checked_at,
        type(^now, :utc_datetime),
        type(^interval, :integer),
        r.counts_failures
      )
    )
  end

  # The member's own act, applied to the stored figure at once (issue #1283).
  #
  # We deliver the `Like` (or the `Announce`) and only learn what the origin did
  # with it on the next ask, which on an older post is hours away. Leaving the
  # number still until then reads as the press having done nothing — and it
  # would survive a reload, which a client-side bump would not. So the one act
  # this reader just performed moves the figure by one, and the next fetch
  # collapses the two by overwriting it with the origin's own answer.
  #
  # Only ever by one, and only when we have a figure at all: adding our stored
  # markers wholesale would double-count every act the origin has already
  # counted, and inventing a `1` where the server tells us nothing would turn
  # "not told" into a claim.
  defp nudge_counts(_subject, nil, _delta), do: :ok

  defp nudge_counts(subject, column, delta) do
    query =
      from(r in subject_schema(subject),
        where: r.id == ^subject.id and not is_nil(field(r, ^column))
      )

    # Never below zero: the origin's answer can land between the like and the
    # unlike, and it may already be back at the figure we are about to decrement.
    query = if delta < 0, do: where(query, [r], field(r, ^column) > 0), else: query

    case Repo.update_all(query, inc: [{column, delta}]) do
      # Read back rather than computed: the struct in hand was rendered at some
      # earlier moment, and the figure may have been refreshed since.
      {1, _} -> subject |> subject_schema() |> Repo.get(subject.id) |> broadcast_moved()
      _none -> :ok
    end
  end

  defp broadcast_moved(nil), do: :ok
  defp broadcast_moved(subject), do: broadcast_counts(subject)

  # What a delivered object already tells us about itself. Free, and it means a
  # fresh post carries its figures from the first render instead of waiting for
  # the first sweep. Only stamps `counts_checked_at` when the object really
  # carried a collection — otherwise the row stays due, so the refresher fills
  # it in on its next run.
  defp put_object_counts(changeset, doc) do
    likes = collection_total(doc["likes"])
    shares = collection_total(doc["shares"])

    if is_nil(likes) and is_nil(shares) do
      changeset
    else
      changeset
      |> Ecto.Changeset.put_change(:likes_count, likes)
      |> Ecto.Changeset.put_change(:shares_count, shares)
      |> Ecto.Changeset.put_change(:counts_checked_at, DateTime.utc_now(:second))
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
    case URI.parse(to_string(target_input)) do
      %URI{scheme: "https", host: h} when is_binary(h) and h != "" ->
        with {:ok, remote} <- verify_alias(user, target_input, Docs.actor_url(user)),
             do: {:ok, remote.id}

      _ ->
        {:error, :invalid_target}
    end
  end

  # The one `alsoKnownAs` check, used in both directions. A move is honored only
  # once the **target's own** actor document names the account it claims to
  # succeed: outbound that is our member moving away (issue #986), inbound it is
  # the remote account that announced the `Move` (issue #1168). Without it any
  # server could hand us a target it liked and walk a subscription — ours or a
  # member's — somewhere nobody chose.
  #
  # `signer` is whose key the fetch is signed with; authorized-fetch instances
  # refuse an anonymous GET.
  defp verify_alias(%User{} = signer, target, claimed_uri) do
    case fetch_remote_actor(target, signer(signer)) do
      {:ok, remote} ->
        cond do
          remote.id == claimed_uri -> {:error, :self_target}
          claimed_uri in remote.also_known_as -> {:ok, remote}
          true -> {:error, :alias_missing}
        end

      _ ->
        {:error, :target_unreachable}
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

  # The member's or page's own key, to sign a remote-actor fetch
  # (authorized-fetch instances reject anonymous GETs); nil without an actor.
  # Public so the inbox controller signs the same way instead of re-spelling
  # the key-id shape.
  @doc false
  def signer(subject), do: signer_for(subject, get_actor(subject))

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
  def claim_reply_budget(%User{id: user_id}),
    do:
      claim_outbound_budget(
        user_id,
        :fediverse_outbound_reply,
        outbound_reply_limit(),
        :reply_capped
      )

  # The one spelling of "one slot from an hourly outbound budget" behind the
  # reply/like/boost claims, so the window and the refusal shape stay uniform.
  defp claim_outbound_budget(user_id, key, limit, error) do
    case RateLimiter.hit({key, user_id}, limit, @inbound_window_ms) do
      :ok -> :ok
      _ -> {:error, error}
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

  The read half of what `account_posts/2` enforces in SQL, for the callers
  holding a post rather than a query: the reply gate above and the picture proxy
  (`remote_image_visible?/2`).

  Deliberately **not** the narrower feed question ("would this reach them
  unprompted"), which a follow of the author answers. Every surface that renders
  a cached post — the feed's own source, a boost, a member's repost, the account
  page — is a subset of this one, so a gate built from the feed question denies
  the other three; that is what broke the pictures on boosted posts. Keep new
  read-side callers on this function — `readable_remote_post_ids/2` below is the
  same rule for a caller holding a whole page, so needing a batch is not a
  reason to spell the two arms again somewhere else.
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
  Which of these cached posts `party` may read, as a `MapSet` of post ids —
  `remote_post_readable?/2` asked once for a whole page rather than once per
  row, and the answer to that function's own "keep new read-side callers on
  this function" for a caller holding a page of them
  (`Vutuv.MastodonApi.Presenter`, naming each reply's parent).

  Same rule, same two arms, composed here so the audience question keeps one
  owner: an open audience is readable outright, a followers-only one needs this
  party's own **accepted** follow — a pending one reads nothing yet, so it would
  name an id the reader's very next request is refused for. Only the closed
  posts put the follow question at all, so a page of public parents pays no
  query. Party-shaped rather than member-only, because a page reads cached posts
  too (`VutuvWeb.MastodonApi.Statuses.visible?/2`), and — faithful to the
  singular — nobody signed in reads nothing.
  """
  def readable_remote_post_ids(_posts, nil), do: MapSet.new()

  def readable_remote_post_ids(posts, party) do
    closed_account_ids =
      posts |> Enum.reject(&RemotePost.open?/1) |> Enum.map(& &1.remote_account_id)

    accepted = remote_follow_account_ids(party, closed_account_ids, :accepted)

    for post <- posts,
        RemotePost.open?(post) or MapSet.member?(accepted, post.remote_account_id),
        into: MapSet.new(),
        do: post.id
  end

  # Claims one slot from the member's hourly like budget. `:ok`, or
  # `{:error, :like_capped}`.
  #
  # Consuming, so only the write path calls it — and only the **like** path: an
  # unlike is a withdrawal, and refusing to let somebody take a like back
  # because they have been busy would be an odd shape of limit.
  defp claim_like_budget(%User{id: user_id}),
    do:
      claim_outbound_budget(
        user_id,
        :fediverse_outbound_like,
        outbound_like_limit(),
        :like_capped
      )

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
  def like_remote_post(%User{} = user, %RemotePost{} = post),
    do: outbound_act(user, post, remote_post_like())

  # The budget is claimed here rather than before the insert, so a double tap or
  # a second tab — which writes nothing and sends nothing — does not spend
  # somebody's slot. A refusal rolls the marker back: a heart painted for a like
  # that never left is the one disagreement a member cannot fix from here.
  # The four acts, each naming only what is its own (see `outbound_act/3`).
  defp remote_post_like do
    %{
      reload: &reload_remote_post/1,
      gate: &check_remote_like/2,
      schema: PostLike,
      fk: :remote_post_id,
      budget: &claim_like_budget/1,
      deliver: fn user, post -> deliver_like(user, post, &Docs.like_activity/3) end,
      undo: fn user, post -> deliver_like(user, post, &Docs.undo_like_activity/3) end,
      counts_column: :likes_count,
      written: :liked,
      undone: :unliked
    }
  end

  defp remote_post_repost do
    %{
      reload: &reload_remote_post/1,
      gate: &check_remote_repost/2,
      schema: PostRepost,
      fk: :remote_post_id,
      budget: &claim_boost_budget/1,
      deliver: fn user, post -> deliver_boost(user, post, &Docs.announce_remote_activity/4) end,
      undo: fn user, post -> deliver_boost(user, post, &Docs.undo_announce_remote_activity/4) end,
      counts_column: :shares_count,
      written: :reposted,
      undone: :unreposted
    }
  end

  defp note_like do
    %{
      reload: &reload_note/1,
      gate: &check_note_like/2,
      schema: NoteLike,
      fk: :note_id,
      budget: &claim_like_budget/1,
      deliver: fn user, note -> deliver_note_like(user, note, &Docs.like_activity/3) end,
      undo: fn user, note -> deliver_note_like(user, note, &Docs.undo_like_activity/3) end,
      counts_column: :likes_count,
      written: :liked,
      undone: :unliked
    }
  end

  defp note_repost do
    %{
      reload: &reload_note/1,
      gate: &check_note_repost/2,
      schema: NoteRepost,
      fk: :note_id,
      budget: &claim_boost_budget/1,
      deliver: fn user, note ->
        deliver_note_boost(user, note, &Docs.announce_remote_activity/4)
      end,
      undo: fn user, note ->
        deliver_note_boost(user, note, &Docs.undo_announce_remote_activity/4)
      end,
      counts_column: :shares_count,
      written: :reposted,
      undone: :unreposted
    }
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
  def unlike_remote_post(%User{} = user, %RemotePost{} = post),
    do: outbound_undo(user, post, remote_post_like())

  @doc """
  Which of `post_ids` this member already likes, as a `MapSet` — one query for a
  whole feed page rather than one per card.
  """
  def liked_remote_post_ids(%User{} = viewer, post_ids) when is_list(post_ids),
    do: marker_ids(PostLike, :remote_post_id, viewer, post_ids)

  def liked_remote_post_ids(_viewer, _post_ids), do: MapSet.new()

  ## The kernels both outbound acts on a cached post are built from — the like
  ## here and the reshare below (issue #1166). The two differ in what they mean
  ## and who they are addressed to, never in how the marker row is written or
  ## how the activity is queued, so those three live once.

  # The join-row kernel every other engagement toggle here writes through
  # (`Vutuv.Engagement`), for the reason `insert_reaction/3` spells out:
  # `Repo.insert(on_conflict: :nothing)` cannot say whether the row landed,
  # because the v7 id is minted in Elixir and the struct comes back looking
  # identical either way, so only the inserted row count is an honest answer.
  # Here that answer decides whether an activity leaves the building. Nothing
  # needs a changeset — both ids come from records the caller already resolved.
  # `written` is what the caller calls a row that really landed.
  # ## One outbound act, four callers
  #
  # Liking a cached post, resharing it, liking a reply and resharing a reply are
  # the same steps in the same order: re-read the subject (the card was rendered
  # at some earlier moment and the row can be gone — expiry, an upstream
  # `Delete`, a takedown, an instance block — and the insert would then hit the
  # foreign key and take the whole LiveView down with it; `on_conflict: :nothing`
  # suppresses the *unique* violation, never this one), ask that act's gate,
  # write the marker, and — only when the row really is new — claim an hourly
  # slot and queue the activity, rolling the marker back if the budget refuses.
  #
  # That last order is the load-bearing part: a marker standing for an activity
  # that never left paints a heart (or a reshare) the other server knows nothing
  # about, which is the one disagreement a member cannot fix from here. And a
  # repeat — a double tap, a second tab — writes nothing, sends nothing and
  # therefore spends no slot.
  #
  # What differs per act is named in `act` and nothing else: the reload, the
  # gate, the marker table and its subject column, which budget it spends, how
  # the activity is addressed, and the word for a row that really landed.
  defp outbound_act(user, subject, act) do
    user = reload_member(user)

    with subject when not is_nil(subject) <- act.reload.(subject),
         :ok <- act.gate.(user, subject),
         {:ok, written} when written == act.written <-
           insert_marker(act.schema, act.fk, user, subject.id, act.written) do
      claim_and_deliver(user, subject, act)
    else
      nil -> {:error, :not_found}
      {:ok, :already} -> {:ok, :already}
      {:error, _} = error -> error
    end
  end

  # Wraps the two acts of `outbound_act/3` that are also **feed sources** — a
  # member passing a cached post or a reply on — so open feeds hear about it
  # (issue #1503). The two hearts beside them are not wrapped: a like changes a
  # figure on a card, it puts no row in anybody's timeline.
  #
  # The stamp is taken **before** the write, never after: the reader's feed asks
  # for a row at or after it, and a stamp read afterwards can sit a tick past
  # the very row it is meant to find. Only a reshare that was really written
  # says anything — a second tab's press answers `{:ok, :already}` and has
  # nothing new to point at.
  defp with_feed_nudge(%User{} = user, act) do
    at = NaiveDateTime.utc_now(:second)

    case act.() do
      {:ok, :reposted} = written ->
        nudge_feeds(resharer_audience(user), at)
        written

      other ->
        other
    end
  end

  # The member as they stand **now**, for the same reason the subject above is
  # re-read: the card was rendered at some earlier moment (issue #1349). Their
  # own copy came from a LiveView mount and every gate here asks about their
  # Fediverse standing — which is a switch they own, and which the refusal sends
  # them off to flip. Reading the copy from the mount meant the tab they left
  # open went on refusing after they had turned it on, so the member who
  # reported this had to reload the feed to be believed.
  #
  # The row going missing mid-act leaves the struct in hand: that is what every
  # caller passed before this existed, and a member deleting their account in
  # another tab is not a case for this function to invent an answer to.
  defp reload_member(%User{} = user), do: Repo.reload(user) || user

  defp claim_and_deliver(user, subject, act) do
    case act.budget.(user) do
      :ok ->
        act.deliver.(user, subject)
        # Only once the activity is really queued: a figure nudged for a like
        # that never left is the same lie as a heart painted for one.
        nudge_counts(subject, act.counts_column, 1)
        {:ok, act.written}

      {:error, _} = capped ->
        delete_marker(act.schema, act.fk, user, subject.id)
        capped
    end
  end

  # The withdrawal half, in one place for the same four callers: drop the row,
  # and queue the `Undo` only when a row really went (so a second tab's press
  # sends nothing). Never gated and never budgeted — refusing to let somebody
  # take an act back because they have been busy would be an odd shape of limit,
  # and it must still go out once the member has stopped federating, which the
  # deliverers handle through `ever_federated?/1` (issue #1102).
  defp outbound_undo(user, subject, act) do
    if delete_marker(act.schema, act.fk, user, subject.id) > 0 do
      act.undo.(user, subject)
      nudge_counts(subject, act.counts_column, -1)
      {:ok, act.undone}
    else
      {:ok, :already}
    end
  end

  ## What a card from another network can do — one vocabulary for both kinds
  ##
  ## `VutuvWeb.PostLive.RemoteActionsComponent` is the only caller. It renders
  ## the same bar for a cached post and for a reply, so it needs to ask about
  ## both in the same words rather than branching on the struct at every step —
  ## the branching lives here, once, beside the acts it dispatches to.

  @doc """
  Performs one act on one subject: `act` is `"like"`, `"repost"` or
  `"bookmark"`, and `on?` says whether it is being switched on or taken back.

  The one entry point the action bar calls, so the bar never has to know which
  of six public functions the pair it holds maps to. Each of those keeps its own
  name and its own doc — this only routes.
  """
  def toggle_engagement(%User{} = user, %Note{} = note, act, on?),
    do: apply(__MODULE__, note_act_fun(act, on?), [user, note])

  def toggle_engagement(%User{} = user, %RemotePost{} = post, act, on?),
    do: apply(__MODULE__, post_act_fun(act, on?), [user, post])

  def toggle_engagement(nil, _subject, _act, _on?), do: {:error, :not_signed_in}

  defp note_act_fun("like", true), do: :like_note
  defp note_act_fun("like", false), do: :unlike_note
  defp note_act_fun("repost", true), do: :repost_note
  defp note_act_fun("repost", false), do: :unrepost_note
  defp note_act_fun("bookmark", true), do: :bookmark_note
  defp note_act_fun("bookmark", false), do: :unbookmark_note

  defp post_act_fun("like", true), do: :like_remote_post
  defp post_act_fun("like", false), do: :unlike_remote_post
  defp post_act_fun("repost", true), do: :repost_remote_post
  defp post_act_fun("repost", false), do: :unrepost_remote_post
  defp post_act_fun("bookmark", true), do: :bookmark_remote_post
  defp post_act_fun("bookmark", false), do: :unbookmark_remote_post

  @doc """
  The three marks for a page of subjects as **one lookup fun**: three batched
  reads up front, then a map read per card.

  Every host that draws more than one card from another network uses this — the
  feed, the permalink conversation, the account page, the tag timeline — so
  "what has this reader already done with these" is three queries per page
  wherever it is asked, and the bars never each ask for themselves. A single
  card (the URL lookup) can skip it: `VutuvWeb.PostLive.RemoteActionsComponent`
  loads its own when the host hands it nothing.

  Takes either kind of subject, or a mixed list.
  """
  def mark_lookup(subjects, viewer) do
    liked = liked_ids(viewer, subjects)
    reposted = reposted_ids(viewer, subjects)
    bookmarked = bookmarked_ids(viewer, subjects)

    fn subject ->
      %{
        liked?: MapSet.member?(liked, subject.id),
        reposted?: MapSet.member?(reposted, subject.id),
        bookmarked?: MapSet.member?(bookmarked, subject.id)
      }
    end
  end

  @doc "Which of these subjects the viewer likes — the batch read, either kind."
  def liked_ids(viewer, subjects), do: batch_ids(viewer, subjects, NoteLike, PostLike)

  @doc "Which of these subjects the viewer has passed on."
  def reposted_ids(viewer, subjects), do: batch_ids(viewer, subjects, NoteRepost, PostRepost)

  @doc "Which of these subjects the viewer has saved."
  def bookmarked_ids(viewer, subjects), do: batch_ids(viewer, subjects, Bookmark, Bookmark)

  # One subject or a list of them, of either kind. A mixed list is split, since
  # the two kinds live in different columns (and, for the bookmarks, different
  # columns of the same table).
  defp batch_ids(nil, _subjects, _note_schema, _post_schema), do: MapSet.new()

  defp batch_ids(%User{} = viewer, subject, note_schema, post_schema) when not is_list(subject),
    do: batch_ids(viewer, [subject], note_schema, post_schema)

  defp batch_ids(%User{} = viewer, subjects, note_schema, post_schema) do
    {notes, posts} = Enum.split_with(subjects, &match?(%Note{}, &1))

    MapSet.union(
      ids_for(note_schema, :note_id, viewer, notes),
      ids_for(post_schema, :remote_post_id, viewer, posts)
    )
  end

  defp ids_for(_schema, _fk, _viewer, []), do: MapSet.new()

  defp ids_for(schema, fk, viewer, subjects),
    do: marker_ids(schema, fk, viewer, Enum.map(subjects, & &1.id))

  ## Saving something from another network for yourself (issue #1276)
  ##
  ## The one act on these cards that stays here. Nothing is signed, nothing is
  ## addressed, nothing leaves the building — so unlike every other act in this
  ## module it asks nothing of the member's Fediverse standing, spends no hourly
  ## budget and has no `Undo` to send. What it does share is the marker fabric
  ## below and the read gate: you may only save what you may read, since the id
  ## in a click is the member's to choose.

  @doc """
  Whether `user` may save this cached post or reply — the read question and
  nothing else.

  Deliberately not `check_remote_like/2`: a bookmark is private and local, so
  the installation switch, the member's own participation and the operator
  blocklist have no bearing on it. A member who does not federate at all can
  still keep something they read.
  """
  def check_bookmark(%User{} = user, %RemotePost{} = post) do
    if remote_post_readable?(post, user), do: :ok, else: {:error, :not_visible}
  end

  def check_bookmark(%User{} = user, %Note{} = note) do
    if note_readable?(note, user), do: :ok, else: {:error, :not_visible}
  end

  @doc """
  Saves a cached post. `{:ok, :bookmarked}`, `{:ok, :already}`, or the gate's
  `{:error, reason}`.
  """
  def bookmark_remote_post(%User{} = user, %RemotePost{} = post),
    do: outbound_act(user, post, remote_post_bookmark())

  @doc "Drops the bookmark. `{:ok, :unbookmarked}` or `{:ok, :already}`."
  def unbookmark_remote_post(%User{} = user, %RemotePost{} = post),
    do: outbound_undo(user, post, remote_post_bookmark())

  @doc "Saves a reply from another network."
  def bookmark_note(%User{} = user, %Note{} = note),
    do: outbound_act(user, note, note_bookmark())

  @doc "Drops the bookmark on a reply."
  def unbookmark_note(%User{} = user, %Note{} = note),
    do: outbound_undo(user, note, note_bookmark())

  @doc "Which of `post_ids` this member has saved, as a `MapSet`."
  def bookmarked_remote_post_ids(%User{} = viewer, post_ids) when is_list(post_ids),
    do: marker_ids(Bookmark, :remote_post_id, viewer, post_ids)

  def bookmarked_remote_post_ids(_viewer, _post_ids), do: MapSet.new()

  @doc "Which of `note_ids` this member has saved, as a `MapSet`."
  def bookmarked_note_ids(%User{} = viewer, note_ids) when is_list(note_ids),
    do: marker_ids(Bookmark, :note_id, viewer, note_ids)

  def bookmarked_note_ids(_viewer, _note_ids), do: MapSet.new()

  @doc """
  One page of what this member saved from other networks, newest first, as feed
  entries — the same shape `/bookmarks` already streams for vutuv posts, so that
  page can interleave the three kinds by saved-at time.

  `q` filters on the saved text, which is the only thing there is to search: a
  cached post and a reply both carry plain text and nothing else we could match
  a member's own words against.
  """
  def saved_from_networks(%User{id: user_id}, opts \\ []) do
    q = opts[:q]
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    from(b in Bookmark,
      left_join: p in RemotePost,
      on: p.id == b.remote_post_id,
      left_join: a in RemoteAccount,
      on: a.id == p.remote_account_id,
      left_join: n in Note,
      on: n.id == b.note_id,
      where: b.user_id == ^user_id,
      order_by: [desc: b.inserted_at, desc: b.id],
      preload: [remote_post: {p, remote_account: a}, note: n]
    )
    |> saved_matching(q)
    |> limit(^(limit + 1))
    |> offset(^offset)
    |> Repo.all()
    |> Enum.map(&saved_entry/1)
  end

  @doc "How many things this member saved from other networks."
  def saved_from_networks_count(%User{id: user_id}),
    do: Repo.aggregate(from(b in Bookmark, where: b.user_id == ^user_id), :count)

  defp saved_matching(query, q) when is_binary(q) and q != "" do
    like = "%" <> String.replace(q, ~r/[%_]/, "") <> "%"

    where(
      query,
      [b, p, a, n],
      ilike(p.content_text, ^like) or ilike(n.content_text, ^like) or ilike(a.handle, ^like) or
        ilike(n.handle, ^like)
    )
  end

  defp saved_matching(query, _q), do: query

  # The saved row as a feed entry: `at` is when it was **saved**, not when it was
  # written, because that is the order the page is in and the order the member
  # remembers.
  defp saved_entry(%Bookmark{remote_post: %RemotePost{} = post} = bookmark),
    do: %{
      id: "saved-remote-post-#{bookmark.id}",
      post: nil,
      remote_post: post,
      reposted_by: nil,
      at: bookmark.inserted_at
    }

  defp saved_entry(%Bookmark{note: %Note{} = note} = bookmark),
    do: %{
      id: "saved-remote-reply-#{bookmark.id}",
      post: nil,
      note: note,
      reposted_by: nil,
      at: bookmark.inserted_at
    }

  # A bookmark spends no budget and sends nothing, so the two act fields the
  # fabric needs are the identity: claim nothing, deliver nothing. Naming them
  # here rather than special-casing `outbound_act/3` keeps that function with one
  # shape for all six acts.
  defp remote_post_bookmark do
    %{
      reload: &reload_remote_post/1,
      gate: &check_bookmark/2,
      schema: Bookmark,
      fk: :remote_post_id,
      budget: fn _user -> :ok end,
      deliver: fn _user, _post -> :skip end,
      undo: fn _user, _post -> :skip end,
      # Nothing to nudge: a bookmark is private and local, so no counter on any
      # server moves because of it.
      counts_column: nil,
      written: :bookmarked,
      undone: :unbookmarked
    }
  end

  defp note_bookmark do
    %{
      reload: &reload_note/1,
      gate: &check_bookmark/2,
      schema: Bookmark,
      fk: :note_id,
      budget: fn _user -> :ok end,
      deliver: fn _user, _note -> :skip end,
      undo: fn _user, _note -> :skip end,
      counts_column: nil,
      written: :bookmarked,
      undone: :unbookmarked
    }
  end

  # ## One marker fabric for everything that came from another network
  #
  # A member's like of a cached post, their reshare of it, their like of a reply
  # and their reshare of a reply are the **same three database operations** four
  # times over — write the row if it is not there, drop it and say whether it
  # really went, and ask which of a page's subjects are marked. The only thing
  # that differs is which column names the subject (`remote_post_id` for a
  # cached post, `note_id` for a reply), so that column is the parameter and
  # there is one of each operation rather than eight.
  #
  # Everything above them stays per-subject on purpose: the gates ask different
  # questions and the activities are addressed differently. This is the layer
  # where they genuinely are identical.

  # The join-row kernel every other engagement toggle here writes through
  # (`Vutuv.Engagement`), for the reason `insert_reaction/3` spells out:
  # `Repo.insert(on_conflict: :nothing)` cannot say whether the row landed,
  # because the v7 id is minted in Elixir and the struct comes back looking
  # identical either way, so only the inserted row count is an honest answer.
  # Here that answer decides whether an activity leaves the building.
  defp insert_marker(schema, fk, user, subject_id, written) do
    case Engagement.insert_if_new(
           schema,
           Map.new([{:user_id, user.id}, {fk, subject_id}]),
           [:user_id, fk]
         ) do
      {:inserted, _row} -> {:ok, written}
      :exists -> {:ok, :already}
    end
  end

  # The withdrawal half, answering in the same currency: how many rows really
  # went, so a second tab's press can be told from a real one.
  defp delete_marker(schema, fk, user, subject_id) do
    {count, _} =
      Repo.delete_all(
        from(r in schema, where: r.user_id == ^user.id and field(r, ^fk) == ^subject_id)
      )

    count
  end

  # Which of `subject_ids` this member has marked — one query per page rather
  # than one per card.
  defp marker_ids(schema, fk, %User{id: user_id}, subject_ids) do
    from(r in schema,
      where: r.user_id == ^user_id and field(r, ^fk) in ^subject_ids,
      select: field(r, ^fk)
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # The activity itself, queued to whichever inboxes the act is addressed to
  # (`inboxes` is handed the post's account, since both answers start there).
  defp deliver_remote_activity(user, %RemotePost{} = post, builder, inboxes) do
    with %RemoteAccount{} = account <- post_account(post),
         # `ever_federated?/1`, never `federated?/1`, for the reason the
         # revocation paths spell out (issue #1102): a withdrawal happens
         # exactly when the state that allowed the original act is already
         # gone. Gating the `Undo` on it would leave the favourite (or the
         # boost) standing under a member's name on a server they can no
         # longer reach.
         true <- ever_federated?(user),
         [_ | _] = list <- inboxes.(account) do
      enqueue(user, list, builder.(user, account.actor_uri, post.object_uri))
    else
      _ -> :skip
    end
  end

  # The author's own inbox, never the shared one: a Like is addressed to one
  # person, and a shared inbox is for what a server fans out to many.
  defp deliver_like(user, %RemotePost{} = post, builder),
    do: deliver_remote_activity(user, post, builder, &List.wrap(&1.inbox_uri))

  defp post_account(%RemotePost{remote_account: %RemoteAccount{} = account}), do: account
  defp post_account(%RemotePost{remote_account_id: id}), do: Repo.get(RemoteAccount, id)

  defp actor_uri_of(%RemotePost{} = post) do
    case post_account(post) do
      %RemoteAccount{actor_uri: uri} -> uri
      _ -> nil
    end
  end

  ## Liking a reply from another network (issue #1270)
  ##
  ## The same act as the heart above, one step further down the conversation:
  ## there it is a post by an account the member follows, here it is an answer
  ## somebody wrote under the member's own post. The activity, the addressing,
  ## the budget and the reasoning are the post path's unchanged — only the row
  ## it is keyed to differs, because a note is its own table.

  @doc """
  Whether `user` may like the stored reply `note`, and when not, which gate
  refused — `check_remote_like/2`'s vocabulary, plus one of this path's own:

    * `:not_deliverable` — the note carries no inbox address, so a `Like` for it
      could not leave the building. Replies stored before issue #1070 have none
      (the column arrived with the answering feature), and for those the card
      offers no heart at all rather than one that refuses: writing the marker
      anyway would paint a heart for a like the author's server never hears
      about, which is the one disagreement a member cannot fix from here.
    * `:not_visible` — the reply is not one this member may read.

  Deliberately **no audience gate**, unlike answering: a `Like` is addressed to
  its author alone and publishes nothing, so a reply sent to the member only
  (issue #1071) can be liked exactly the way a public one can. What the two
  paths do share is that the id in a click is attacker-controlled, so the read
  question is asked here and not left to the fact that the LiveView resolved it
  against its own rendered list.

  Free of side effects, so a render may ask it. The budget is claimed separately.
  """
  def check_note_like(%User{} = user, %Note{} = note) do
    cond do
      not enabled?() -> {:error, :fediverse_disabled}
      not Note.likeable?(note) -> {:error, :not_deliverable}
      not federated?(user) -> {:error, :not_federating}
      moved?(user) -> {:error, :moved}
      instance_blocked?(note.actor_uri) -> {:error, :instance_blocked}
      not note_readable?(note, user) -> {:error, :not_visible}
      true -> :ok
    end
  end

  @doc """
  Whether `viewer` may read this stored reply: a public one is everybody's,
  anything else only ever the member whose post it answers.

  The same rule `list_notes/2` enforces in SQL for the conversation, for the
  callers holding a single row — so a reply nobody else may see cannot be liked
  (or its existence confirmed) by guessing its id.
  """
  def note_readable?(%Note{} = note, %User{id: viewer_id}) do
    Note.public?(note) or
      Repo.exists?(from(p in Post, where: p.id == ^note.post_id and p.user_id == ^viewer_id))
  end

  def note_readable?(_note, _viewer), do: false

  @doc """
  The member likes a reply from another network: writes the local marker and
  queues a signed `Like` to its author's own inbox.

  `{:ok, :liked}`, `{:ok, :already}` when the marker was already there (a double
  tap, or a second tab — no second activity goes out), or the gate's
  `{:error, reason}`.

  Marker first, activity after, for the reason the post path spells out: a
  queued activity whose marker failed to write would paint no heart while the
  author's server counts the like.
  """
  def like_note(%User{} = user, %Note{} = note),
    do: outbound_act(user, note, note_like())

  # The budget is claimed here rather than before the insert, so a double tap or
  # a second tab — which writes nothing and sends nothing — does not spend
  # somebody's slot. It is the **same** hourly budget the post heart claims:
  # both are one member's like leaving for another network, and metering them
  # apart would let an hour of one hide inside the other's allowance.

  @doc """
  The member takes the like back: drops the marker and queues the matching
  `Undo(Like)`.

  `{:ok, :unliked}` or `{:ok, :already}`. No gate and no budget — a withdrawal
  must not be refusable, and if the member has since stopped federating there is
  simply nothing to send.
  """
  def unlike_note(%User{} = user, %Note{} = note),
    do: outbound_undo(user, note, note_like())

  @doc """
  Which of `note_ids` this member already likes, as a `MapSet` — one query for a
  whole conversation rather than one per card.
  """
  def liked_note_ids(%User{} = viewer, note_ids) when is_list(note_ids),
    do: marker_ids(NoteLike, :note_id, viewer, note_ids)

  def liked_note_ids(_viewer, _note_ids), do: MapSet.new()

  @doc """
  Every reply from another network this member likes — for their GDPR export and
  for the withdrawal below, which needs the same rows.
  """
  def list_note_likes(%User{id: user_id}) do
    Repo.all(
      from(l in NoteLike,
        join: n in Note,
        on: n.id == l.note_id,
        where: l.user_id == ^user_id,
        order_by: [desc: l.id],
        select: n
      )
    )
  end

  @doc """
  Withdraws every like this member holds on replies from other networks and
  drops the markers — the note half of `drop_remote_likes/1`, called from the
  same place and for the same reason: what stands on other servers under their
  name goes with the decision to leave rather than after it.
  """
  def drop_note_likes(%User{} = user) do
    Enum.each(list_note_likes(user), fn note ->
      deliver_note_like(user, note, &Docs.undo_like_activity/3)
    end)

    {count, _} = Repo.delete_all(from(l in NoteLike, where: l.user_id == ^user.id))
    count
  end

  @doc """
  This stored reply as it is **now**, or nil once the row is gone. Every write
  path acting on a reply a member is looking at goes through here first, for the
  reason `reload_remote_post/1` spells out.
  """
  def reload_note(%Note{id: id}), do: Repo.get(Note, id)

  # The marker kernel, written through `Vutuv.Engagement.insert_if_new/3` like
  # every other engagement toggle here: only the inserted row count is an honest
  # answer to "did this request create the like", and that answer is what decides
  # whether an activity leaves the building.

  # The author's own inbox, never a shared one: a Like is addressed to one
  # person. `ever_federated?/1` rather than `federated?/1`, so a withdrawal still
  # reaches the server a member can no longer sign new acts for (issue #1102) —
  # and nothing is sent at all for a note that never carried an address, which
  # `check_note_like/2` refuses up front anyway.
  defp deliver_note_like(%User{} = user, %Note{} = note, builder) do
    with inbox when is_binary(inbox) <- note.inbox_uri,
         true <- ever_federated?(user) do
      enqueue(user, [inbox], builder.(user, note.actor_uri, note.object_uri))
    else
      _ -> :skip
    end
  end

  ## Passing a reply from another network on (issue #1275)
  ##
  ## `repost_remote_post/2` (issue #1166) for a note. Same activity, same
  ## addressing, same budget — and one thing the like beside it does not have:
  ## the reshare is a **feed source**, because a button that publishes to other
  ## servers and shows nothing on the site it was pressed on is a button that
  ## did nothing as far as the member can tell.

  @doc """
  Whether `user` may pass this reply on, and when not, which gate refused —
  `check_note_like/2`'s vocabulary plus the one a publishing act adds:

    * `:note_not_public` — its author addressed it to the member alone (issue
      #1071). A reshare hands it to everybody who follows the resharer here and
      out there, and passing on an audience its author narrowed is not ours to
      do, so the card offers no control there rather than one that refuses.

  The audience question is asked **first**, for the reason the cached post's
  gate spells out: no setting of the member's own could ever make a private
  reply shareable, so telling them to go and switch something on would be a lie.
  """
  def check_note_repost(%User{} = user, %Note{} = note) do
    if Note.public?(note),
      do: check_note_like(user, note),
      else: {:error, :note_not_public}
  end

  @doc """
  The member passes a reply on: writes the row and queues a signed `Announce` to
  their own followers (and the reply's author, so that server learns of it).

  `{:ok, :reposted}`, `{:ok, :already}`, or the gate's `{:error, reason}`. The
  reply is re-read first, like the heart's: the row can be gone by the time the
  button is pressed and the audience can have narrowed, and neither may be
  decided from the struct the page rendered with.
  """
  def repost_note(%User{} = user, %Note{} = note),
    do: with_feed_nudge(user, fn -> outbound_act(user, note, note_repost()) end)

  @doc """
  The member takes the reshare back: drops the row and queues the matching
  `Undo(Announce)`.

  No gate and no budget, like unliking — a withdrawal must not be refusable, and
  it must go out even once the member has stopped federating (issue #1102).
  """
  def unrepost_note(%User{} = user, %Note{} = note),
    do: outbound_undo(user, note, note_repost())

  @doc """
  Which of `note_ids` this member has passed on, as a `MapSet` — one query for a
  whole page rather than one per card.
  """
  def reposted_note_ids(%User{} = viewer, note_ids) when is_list(note_ids),
    do: marker_ids(NoteRepost, :note_id, viewer, note_ids)

  def reposted_note_ids(_viewer, _note_ids), do: MapSet.new()

  @doc """
  Withdraws every reshare of a reply this member holds and drops the rows — the
  note half of what leaving the Fediverse means for `Announce`, called beside
  `drop_note_likes/1`.
  """
  def drop_note_reposts(%User{} = user) do
    Enum.each(list_note_reposts(user), fn note ->
      deliver_note_boost(user, note, &Docs.undo_announce_remote_activity/4)
    end)

    {count, _} = Repo.delete_all(from(r in NoteRepost, where: r.user_id == ^user.id))
    count
  end

  @doc "Every reply this member has passed on — for the withdrawal above."
  def list_note_reposts(%User{id: user_id}) do
    Repo.all(
      from(r in NoteRepost,
        join: n in Note,
        on: n.id == r.note_id,
        where: r.user_id == ^user_id,
        order_by: [desc: r.id],
        select: n
      )
    )
  end

  @doc """
  The seventh feed source (issue #1275): **replies** from another network that
  people the viewer follows **here** have passed on.

  The exact twin of `feed_remote_reposts/3` one table over, and scoped the same
  way — to the resharer, never to any follow of the author, because being
  vouched for by somebody here is the whole reason this row reaches a member who
  follows nobody out there. Stamped with the reshare time: what is new is the
  sharing, and it lands on the vutuv tab for the same reason.
  """
  def feed_remote_reply_reposts(viewer, fetch_n, cursor, opts \\ [])

  def feed_remote_reply_reposts(%User{id: viewer_id} = viewer, fetch_n, cursor, opts) do
    if enabled?() do
      from(r in NoteRepost,
        join: n in Note,
        as: :language_source,
        on: n.id == r.note_id,
        join: resharer in User,
        as: :resharer,
        on: resharer.id == r.user_id,
        # Only ever what the resharer could have shared: the audience gate is the
        # same one that let them press the button, re-asked here because a note's
        # audience can be narrowed by an upstream `Update` after the fact.
        where: n.audience == "public",
        order_by: [desc: r.inserted_at, desc: r.id],
        preload: [note: n, user: resharer]
      )
      |> scope_resharer(viewer_id, Keyword.get(opts, :only))
      |> reject_muted_note_hosts(viewer)
      |> Vutuv.Posts.named_language_scope(Vutuv.Posts.feed_language_filter(viewer))
      |> limit(^fetch_n)
      |> note_reposts_at_or_before(cursor)
      |> Repo.all()
      |> Enum.map(&remote_reply_repost_entry/1)
    else
      []
    end
  end

  defp note_reposts_at_or_before(query, nil), do: query

  defp note_reposts_at_or_before(query, %{at: at}),
    do: where(query, [r], r.inserted_at <= ^at)

  defp remote_reply_repost_entry(%NoteRepost{} = repost) do
    %{
      id: "remote-reply-repost-#{repost.id}",
      post: nil,
      note: repost.note,
      reposted_by: repost.user,
      at: repost.inserted_at
    }
  end

  # The resharer's own audience — that is the act — plus the reply's author, so
  # their server learns of it, exactly as `deliver_boost/3` addresses a cached
  # post's. The author's inbox is the one the note already carries; a note with
  # none still reaches the resharer's followers, which is the whole audience that
  # matters here (a `Like` has no such fallback, which is why it refuses).
  defp deliver_note_boost(%User{} = user, %Note{} = note, builder) do
    with true <- ever_federated?(user),
         [_ | _] = inboxes <-
           Enum.uniq(delivery_inboxes(user) ++ List.wrap(note.inbox_uri)) do
      enqueue(user, inboxes, builder.(user, note.actor_uri, note.object_uri, note.audience))
    else
      _ -> :skip
    end
  end

  # A content-free record that a followed account deleted itself (issue #1168):
  # which server, how many follows and cached posts went with it, and nothing
  # about the person. Keeping their actor URI would undo what the deletion is
  # for; the keyed digest groups a server across events without being reversible
  # from a database leak. What it buys is that a mass departure — a whole server
  # closing, a botched migration — is visible in the morning report instead of
  # being a silent hole in everybody's feed.
  # A content-free record that a followed account is gone (issue #1168): which
  # server, how many follows and cached posts went with it, and nothing about
  # the person — keeping their actor URI would undo what the deletion is for.
  #
  # A **log line, not the takedown ledger**, though the shape would fit. That
  # ledger's own policy is that automatic deletions stay out of it, "because an
  # expiry sweep, a server block or an upstream `Delete` can remove thousands of
  # rows at once and would drown the signal" — and this is exactly an upstream
  # `Delete` and an automatic prune. Its page is headed "taken down by members"
  # and shows 25 rows; one closing server would push the whole member-takedown
  # trail off it. What this is for is that a mass departure shows up in the
  # operator's logs and the morning report instead of being a silent hole in
  # everybody's feed, and a log line does that without lying about who deleted
  # what.
  defp log_account_gone(actor_uri, accounts) do
    ids = Repo.all(from(a in accounts, select: a.id))

    if ids != [] do
      follows = Repo.aggregate(from(f in Follow, where: f.remote_account_id in ^ids), :count)
      posts = Repo.aggregate(from(p in RemotePost, where: p.remote_account_id in ^ids), :count)

      Logger.info(
        "fediverse followed account gone: host=#{BlockedInstance.normalize_host(actor_uri) || "unknown"} " <>
          "follows=#{follows} cached_posts=#{posts}"
      )
    end

    :ok
  end

  ## When a followed account moves, dies or vanishes (issue #1168)

  @doc """
  Re-checks the accounts members follow out there, on the same slow rotation the
  follower pruner uses in the other direction (issue #1072): at most
  `prune_batch/0` rows an hour, at most `@prune_per_host` of them from any one
  server, nothing re-checked inside `prune_recheck_days/0`.

  Two things come out of one request. An account that answers **404 or 410** is
  gone and is removed with everything hanging off it — that is the silent
  disappearance nobody announces, and the case a follow would otherwise point at
  a husk forever. Anything else (a timeout, a 5xx, a 429, a 403) changes
  nothing but the clock: a server having a bad week must not cost its members
  their followers here, in either direction.

  And a **200** re-syncs the display name and handle, so a rename surfaces
  without waiting for an inbound `Update` that some implementations never send.

  Returns how many accounts were removed.
  """
  def prune_due_remote_accounts(now \\ DateTime.utc_now(:second)) do
    if enabled?(), do: do_prune_due_remote_accounts(now), else: 0
  end

  @doc """
  The followed accounts due for a re-check: never checked, or last checked
  longer than `prune_recheck_days/0` ago. Same bounds and same per-host spread
  as `followers_due_for_prune/1`.
  """
  def remote_accounts_due_for_prune(now \\ DateTime.utc_now(:second)) do
    cutoff = DateTime.add(now, -@prune_recheck_days * 86_400)

    from(a in RemoteAccount,
      join: f in Follow,
      on: f.remote_account_id == a.id,
      where: is_nil(a.refreshed_at) or a.refreshed_at < ^cutoff,
      # A moved account is not missing, it is elsewhere, and its husk goes when
      # the successor accepts. Re-fetching it would only delete the record of
      # what the member had.
      where: is_nil(a.moved_to),
      distinct: true,
      order_by: [asc_nulls_first: a.refreshed_at, asc: a.id],
      # A wider window than one batch, for the reason the follower pruner gives:
      # one server with thousands of stale rows would otherwise fill the batch
      # by itself and the per-host cap would leave the run half empty.
      limit: ^(@prune_batch * 4)
    )
    |> Repo.all()
    |> spread_across_hosts(& &1.host)
  end

  defp do_prune_due_remote_accounts(now) do
    now
    |> remote_accounts_due_for_prune()
    |> count_pruned(&check_remote_account(&1, now))
  end

  defp check_remote_account(%RemoteAccount{} = account, now) do
    # Any follower at all, whatever state their follow is in: somebody still
    # waiting for an answer has just as much reason to ask whether the account
    # is still there.
    follower = any_follower_of(account, Follow.states())

    case fetch_remote_actor(account.actor_uri, follower && signer(follower)) do
      {:error, {:http, status}} when status in @gone_statuses ->
        remove_remote_account(account.actor_uri)
        :pruned

      # A 200 is also the cheapest rename channel there is: some servers never
      # send an `Update` of themselves at all. But **only** for a document that
      # still claims to be this account: the row is looked up by its own actor
      # URI, so nothing else forces the answer to be about it, and
      # `remote_account_attrs/1` writes `actor_uri` and `host`. Without this
      # guard a followed account could quietly become a different one — on a
      # blocked host, or impersonating somebody whose row we do not hold — and
      # the member's follow would still be attached to it.
      {:ok, %{id: id} = remote} when id == account.actor_uri ->
        account
        |> RemoteAccount.changeset(remote_account_attrs(remote))
        |> Repo.update()

        :kept

      # It answered, but about somebody else. Not gone, so not pruned; the clock
      # moves so the rotation stays polite.
      {:ok, _other} ->
        touch_remote_account(account, now)

      _ ->
        touch_remote_account(account, now)
    end
  end

  defp touch_remote_account(%RemoteAccount{} = account, now) do
    account |> Ecto.Changeset.change(refreshed_at: now) |> Repo.update()
    :kept
  end

  @doc """
  A followed account announced it moved (`Move { actor, target }`).

  The member keeps their subscription without lifting a finger: each follow of
  the old account is re-pointed at the successor — a fresh `Follow` goes out and
  the old row is marked `moved` — and the swap completes when the successor
  accepts. Until then the old row survives, so a move the successor never
  answers leaves a record of what the member had rather than losing it silently.

  **Nothing happens without verification.** The successor's own actor document
  must name the old URI in its `alsoKnownAs`, which is exactly the check every
  other server performs on us when one of our members moves out (issue #986).
  Without it, any server could redirect the followers of any account it could
  name — an unverified `Move` is a no-op, deliberately without a word to
  anybody, since it is somebody else's failed or forged migration.

  Returns `:ok` or `:skip`; the inbox answers 202 either way.
  """
  def record_remote_move(activity, actor_uri) when is_binary(actor_uri) do
    with true <- enabled?(),
         %RemoteAccount{} = old <- Repo.get_by(RemoteAccount, actor_uri: actor_uri),
         target when is_binary(target) <- activity_object_id(activity["target"]),
         :ok <- check_follow_host(target),
         # The first of them signs the successor fetch: an authorized-fetch
         # server refuses an anonymous GET, and every follower has an interest
         # in where this account went.
         [%Follow{user: %User{} = signer} | _] = follows <- follows_of(old),
         {:ok, remote} <- verify_alias(signer, target, actor_uri),
         # Again on the **canonical id the document claims**, for the reason
         # `resolve_remote_account/2` checks three times on one follow: each hop
         # can land somewhere else than the last. Without this a followed
         # account names an innocent decoy as its target, the decoy answers with
         # an `id` and `inbox` on a blocked host — or on any host it likes — and
         # we would mint a row for it and queue a member-signed `Follow` at that
         # inbox. The blocklist would be bypassed and an arbitrary https inbox
         # would receive our member's signature.
         :ok <- check_follow_host(remote.id),
         {:ok, successor} <- upsert_remote_account(remote) do
      Repo.update(Ecto.Changeset.change(old, moved_to: successor.actor_uri))
      Enum.each(follows, &repoint_follow(&1, successor))
      broadcast_remote_follows_changed(Enum.map(follows, & &1.user_id))
      :ok
    else
      _ -> :skip
    end
  end

  def record_remote_move(_activity, _actor_uri), do: :skip

  defp repoint_follow(%Follow{user: %User{} = user} = follow, %RemoteAccount{} = successor) do
    # A fresh request to the successor, exactly as if the member had typed the
    # new address: it is a new relationship on a new server, and that server
    # gets to decide about it like any other. So it passes the gates a typed
    # follow passes — a member who is frozen, suspended or has moved out
    # themselves does not get a signed request sent in their name because
    # somebody else's server announced a move.
    case start_follow(user, successor) do
      :ok ->
        Repo.update(Ecto.Changeset.change(follow, state: Follow.moved()))

      # Nothing was sent and nothing will answer: the member already follows
      # the successor, or a gate refused. Leaving a husk here would leave it
      # forever, since only an `Accept` settles one — so the old follow simply
      # ends, which is what it now is.
      :skip ->
        Repo.delete(follow)
    end
  end

  defp start_follow(%User{} = user, %RemoteAccount{} = successor) do
    with :ok <- check_can_follow(user),
         :ok <- check_follow_limit(user),
         {:ok, new_follow} <- insert_remote_follow(user, successor) do
      enqueue(
        user,
        [successor.inbox_uri],
        Docs.follow_activity(user, successor.actor_uri, new_follow.follow_activity_id)
      )

      :ok
    else
      _ -> :skip
    end
  end

  # Every follow of this account, with the member behind it: they are re-pointed
  # one by one and each outbound `Follow` is signed with its own member's key.
  defp follows_of(%RemoteAccount{id: id}),
    do:
      Repo.all(
        from(f in Follow,
          where: f.remote_account_id == ^id,
          order_by: [asc: f.id],
          preload: [:user]
        )
      )

  # Finishes a move once the successor accepts: the husks left behind
  # (`state: "moved"`) for accounts that moved *here* are dropped. Called from
  # the `Accept` path, so the old follow outlives the request exactly as long as
  # it takes the new server to answer.
  defp settle_moved_follows(%User{id: user_id}, successor_uri) when is_binary(successor_uri) do
    moved_from =
      from(a in RemoteAccount, where: a.moved_to == ^successor_uri, select: a.id)

    Repo.delete_all(
      from(f in Follow,
        where:
          f.user_id == ^user_id and f.state == ^Follow.moved() and
            f.remote_account_id in subquery(moved_from)
      )
    )

    :ok
  end

  ## What a followed account re-shares (issue #1167)

  @doc """
  Records an `Announce` from an account somebody here follows.

  Much of what an account contributes is boosts, and until this existed every
  one of them fell through: an `Announce` only ever counted as a reaction to a
  member's **own** post, so a followed account resharing a third party was
  invisible to its followers here.

  Two shapes, and the cheap one is checked first:

    * the announced object is a **vutuv member's** post. No network call at all
      — we wrote it — and this is how members get discovered through the
      outside network.
    * otherwise it is a post on some other server, possibly a **third** one we
      have never spoken to. Storing it means dereferencing the object, which is
      a new outbound surface and is fenced like one: the sending actor must be
      followed here with an accepted follow, neither the object's host nor its
      author's host may be blocked, the fetch is signed, SSRF-checked,
      size-capped and metered per host, and only a public or unlisted object is
      stored at all. A failed fetch drops the `Announce` silently — no retry,
      because a boost is not worth a queue.

  Returns `:ok` or `:skip`; the inbox answers 202 either way.
  """
  def record_remote_boost(activity, actor_uri) when is_binary(actor_uri) do
    with true <- enabled?(),
         %RemoteAccount{} = account <- followed_account(actor_uri),
         uri when is_binary(uri) <- activity_object_id(activity["object"]),
         false <- instance_blocked?(uri),
         # The same inbound cap every other recorder here claims. The per-host
         # fetch budget below only meters the *dereference*, so without this a
         # boost of a member's own post — or of a post we already hold — is a
         # free write, and an account that boosts relentlessly is an account
         # that writes here relentlessly.
         :ok <- check_inbound_cap(actor_uri),
         {:ok, target} <- resolve_announced(account, uri) do
      insert_boost(account, target, activity)
    else
      _ -> :skip
    end
  end

  def record_remote_boost(_activity, _actor_uri), do: :skip

  @doc """
  Removes a boost an account took back (`Undo(Announce)`), by the id the
  original `Announce` carried.

  Scoped to the account that sent the withdrawal, so one server cannot undo
  another's. The post itself stays: something else may still hold it (a follow
  of its author, a member's own reshare, another account's boost), and if
  nothing does the ordinary sweeps take it.
  """
  def remove_remote_boost(activity, actor_uri) when is_binary(actor_uri) do
    with %RemoteAccount{} = account <- followed_account(actor_uri),
         id when is_binary(id) <- activity_object_id(activity["object"]) do
      Repo.delete_all(
        from(b in PostBoost,
          where: b.remote_account_id == ^account.id and b.activity_id == ^id
        )
      )
    end

    :ok
  end

  def remove_remote_boost(_activity, _actor_uri), do: :ok

  # A vutuv member's own post first: it costs nothing to recognise and is the
  # case the whole "discovered through the outside network" argument rests on.
  defp resolve_announced(%RemoteAccount{} = account, uri) do
    case local_note_post(uri) do
      %Post{} = post -> {:ok, post}
      nil -> fetch_announced(account, uri)
    end
  end

  # The announced object as a cached post, fetched if we do not already hold it.
  # Already holding it is the common case on a busy account and is worth not
  # asking twice.
  defp fetch_announced(%RemoteAccount{} = account, uri) do
    case Repo.get_by(RemotePost, object_uri: uri) do
      %RemotePost{} = post -> {:ok, post}
      nil -> fetch_and_store_announced(account, uri)
    end
  end

  defp fetch_and_store_announced(%RemoteAccount{} = booster, uri) do
    with :ok <- claim_announce_fetch(uri),
         %User{} = follower <- any_follower_of(booster, ["accepted"]),
         key when not is_nil(key) <- signer(follower),
         {:ok, doc} <- fetch_remote_note(uri, key),
         # The same object-type gate the `Create` path applies: a `Video`, an
         # `Article` or an `Event` with a `content` field is not a post.
         %{} = doc <- remote_post_object(doc),
         author_uri when is_binary(author_uri) <- announced_author(doc),
         true <- own_object?(uri, doc, author_uri),
         false <- instance_blocked?(author_uri),
         audience when is_binary(audience) <- announced_audience(doc),
         %RemoteAccount{} = author <- announced_author_account(author_uri, key),
         {:ok, post} <- insert_remote_post(author, doc, audience) do
      attach_pictures(post, doc)
      {:ok, post}
    else
      # Another delivery stored it while this one was fetching; the row is what
      # we wanted either way, and its pictures are that delivery's business.
      {:exists, post} -> {:ok, post}
      _ -> :skip
    end
  end

  # A server may only speak for itself. Nothing else in this subsystem needs
  # this check, because every other stored post arrives from the actor whose
  # HTTP signature we verified — this is the one path where a post row is bound
  # to an account the request did not prove, so the document has to prove it.
  #
  # Without it a followed server serves a Note claiming `attributedTo` any actor
  # it likes, and we store its words under that person's real name, handle and
  # avatar, visible to every follower of the booster and on the impersonated
  # account's own page. They could never get it removed either: their genuine
  # `Delete` names an object URI on their own host, and the row is keyed on the
  # forger's. Squatting a real post's `id` before it reaches us would poison it
  # the same way, for the row's whole life.
  #
  # Three cheap conditions: the document is the object we asked for, its author
  # lives on the object's own host, and it does not claim to be one of **ours**
  # — a local actor URI would make us fetch ourselves and mint a foreign-looking
  # account row for a member.
  defp own_object?(uri, doc, author_uri) do
    object_id = SearchText.normalize_search(doc["id"]) || uri

    same_host?(uri, object_id) and same_host?(object_id, author_uri) and
      not own_host?(author_uri)
  end

  # The author of the boosted post, as an account row. Usually a **third**
  # server: neither ours nor the booster's, and one we may never have spoken to.
  # A row already here is used as is — the common case once one of their posts
  # has been seen — and otherwise their actor document is fetched, because a
  # card has to name who wrote the thing and an actor URI alone names nobody.
  defp announced_author_account(author_uri, key) do
    case Repo.get_by(RemoteAccount, actor_uri: author_uri) do
      %RemoteAccount{} = account ->
        account

      nil ->
        with {:ok, remote} <- fetch_remote_actor(author_uri, key),
             {:ok, account} <- upsert_remote_account(remote) do
          account
        else
          _ -> nil
        end
    end
  end

  # Public and unlisted only, the same vocabulary everything else here reads.
  # Anything narrower is dropped unseen: an account boosting a followers-only
  # post of somebody else's does not make it ours to store.
  defp announced_audience(doc) do
    audience = remote_post_audience(doc, doc)
    if audience in RemotePost.open_audiences(), do: audience
  end

  defp announced_author(%{"attributedTo" => actor}), do: activity_object_id(actor)
  defp announced_author(_doc), do: nil

  # A vutuv post URL of any member, not just one — a followed account can boost
  # anybody here. Anchored on `local_path/1`, the way `local_username/1` reads
  # an addressee (so the `www.`/`http` spellings count): a foreign URL that
  # merely copies the `/name/posts/id` shape names nothing of ours and has to
  # be fetched like any other stranger's. Unlike `local_lookup_post/1` this one
  # deliberately requires the handle and the id to agree — it decides whether a
  # member's post may be redistributed on a remote actor's say-so.
  defp local_note_post(uri) do
    with [username, "posts", post_id] <- local_path(uri),
         %User{} = user <- Accounts.get_user_by_username(username),
         %Post{user_id: user_id} = post when user_id == user.id <-
           UUIDv7.with_cast(post_id, &Repo.get(Post, &1)),
         # A member who has not opted into federation is not redistributed on a
         # remote actor's say-so, and one whose account is frozen, suspended,
         # deactivated or unconfirmed is not amplified at all. `federated?/1` is
         # the test every outbound path here already asks.
         true <- federated?(user),
         false <- Posts.restricted?(post) do
      post
    else
      _ -> nil
    end
  end

  # Somebody here who follows this account, to sign a fetch to its server with:
  # an authorized-fetch server refuses an anonymous GET, and a follower is by
  # definition somebody with an interest in the answer. `states` says which
  # follows count — only a settled one when the question is what the account
  # shares, any of them when it is whether the account is still there at all.
  defp any_follower_of(%RemoteAccount{id: id}, states) do
    Repo.one(
      from(f in Follow,
        join: u in User,
        on: u.id == f.user_id,
        where: f.remote_account_id == ^id and f.state in ^states,
        order_by: [asc: f.id],
        limit: 1,
        select: u
      )
    )
  end

  defp claim_announce_fetch(uri) do
    # Keyed on the normalised host, like the inbound caps: one server is one
    # budget however it spells itself.
    with host when is_binary(host) <- BlockedInstance.normalize_host(uri),
         :ok <-
           RateLimiter.hit(
             {:fediverse_announce_fetch, host},
             announce_fetch_limit(),
             @inbound_window_ms
           ) do
      :ok
    else
      _ -> :capped
    end
  end

  @doc "How many announced objects may be dereferenced from one host per hour."
  def announce_fetch_limit,
    do: Application.get_env(:vutuv, :fediverse_announce_fetch_limit, @announce_fetch_limit)

  defp insert_boost(%RemoteAccount{} = account, target, activity) do
    attrs =
      %{
        activity_id: activity["id"],
        announced_at: published_at(activity["published"], DateTime.utc_now(:second))
      }
      |> Map.merge(boost_target(target))

    # A bare `DO NOTHING`, with no conflict target: the table's two unique
    # indexes are partial (one per kind of thing boosted), so naming one would
    # mean restating its `WHERE` here verbatim and keeping the copy in step with
    # the migration by hand. A redelivery is the only conflict there is, and the
    # row it collides with is the one we wanted.
    %PostBoost{remote_account_id: account.id}
    |> PostBoost.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing)
    |> nudge_boost_feeds(account, target, attrs.announced_at)

    :ok
  end

  # An `Announce` is delivered once per local follower too, so the nudge has to
  # know whether *this* delivery wrote the row. `DO NOTHING` cannot say (the id
  # is minted here, not by Postgres, so the struct comes back looking inserted
  # either way), so the row is read back by what the unique indexes cover and
  # its id compared — the same read-back `stored_post/2` does for a cached post.
  #
  # Which tab lights up follows what was boosted, not where it came from: a
  # followed account passing a **member's** post on is a vutuv-tab entry
  # (issue #1167), and the reader may be sitting on the Fediverse tab when it
  # lands.
  defp nudge_boost_feeds({:ok, %PostBoost{id: minted}}, account, target, announced_at) do
    if stored_boost_id(account, target) == minted do
      nudge_feeds(
        followers_of_account(account, accepted: true),
        DateTime.to_naive(announced_at)
      )
    end
  end

  defp nudge_boost_feeds(_result, _account, _target, _announced_at), do: :ok

  defp stored_boost_id(%RemoteAccount{id: account_id}, %RemotePost{id: post_id}) do
    Repo.one(
      from(b in PostBoost,
        where: b.remote_account_id == ^account_id and b.remote_post_id == ^post_id,
        select: b.id
      )
    )
  end

  defp stored_boost_id(%RemoteAccount{id: account_id}, %Post{id: post_id}) do
    Repo.one(
      from(b in PostBoost,
        where: b.remote_account_id == ^account_id and b.post_id == ^post_id,
        select: b.id
      )
    )
  end

  defp boost_target(%RemotePost{id: id}), do: %{remote_post_id: id}
  defp boost_target(%Post{id: id}), do: %{post_id: id}

  ## Looking a post up by its URL (issue #1211)

  @doc """
  Fetches the post behind a pasted URL, so a member can answer, like or reshare
  it (issue #1211).

  ActivityPub pushes only what happens **after** a follow is accepted, so
  everything an account published before that is simply not here: no
  `fediverse_posts` row, nothing to reply to, and the account page deliberately
  fetches nothing on view. This is the one door in — a member pastes the URL
  they are looking at and gets that post as an ordinary remote card.

  Four answers, because four things can be pasted:

    * `{:ok, post}` — a post on another network, cached already or fetched now,
      with its account preloaded.
    * `{:local, post}` — a **vutuv** post URL. It costs no request to recognise
      and the reader wants its permalink, not a copy of it.
    * `{:account, address}` — an account address or profile URL rather than a
      post. Not an error: it is what the follow box on
      `/settings/fediverse/following` is for, so the caller hands it over.
    * `{:error, reason}` — see below.

  Everything downstream of the fetch is the announce path's chain unchanged
  (`fetch_and_store_announced/2`, issue #1167): the object-type gate, the
  `own_object?/3` anti-impersonation check, public and unlisted only, the
  author's actor upserted, the pictures through the AI gate. What differs is the
  way in, and every part of it is because a **member** asked rather than a
  remote server:

    * they must federate. The GET is signed with their own key, so there is no
      such thing as an actorless lookup — `:not_federating` is the one refusal
      they can act on, and the page turns it into the switch rather than a dead
      end (the `check_remote_reply/2` pattern).
    * the operator blocklist is checked on the pasted host, on the canonical
      object id the document claims and on the author's host, since each can be
      somewhere else than the last.
    * an hourly per-member budget (`lookup_limit/0`) bounds it.

  **A post we already hold is returned without a fetch and without claiming
  budget**, whichever of its two URLs was pasted: the canonical object id
  servers exchange, or the display URL people copy out of their browser.

  Any account and any age. The copy gets a hold against the unfollowed purge
  (`Vutuv.Fediverse.PostLookup`) because the author is usually somebody nobody
  here follows, and `expires_at` counts from receipt, so an old post lives out
  the ordinary clock from the lookup rather than arriving already expired.

  Refusals: `:fediverse_disabled`, `:not_federating`, `:moved`,
  `:instance_blocked` (the vocabulary the rest of this subsystem speaks), plus
  `:invalid_post_url` (not a link at all), `:local_url` (a vutuv link that is
  not a post), `:lookup_capped` (the budget), `:post_unreachable` (that server
  did not answer, or not with a document), `:not_a_post` (it answered with
  something that is not a post, or with one whose author it may not speak for)
  and `:post_not_public` (addressed narrower than public or unlisted).
  """
  def look_up_post(%User{} = user, input) when is_binary(input) do
    url = String.trim(input)

    if url == "", do: {:error, :invalid_post_url}, else: classify_lookup(user, url)
  end

  def look_up_post(_user, _input), do: {:error, :invalid_post_url}

  # What was pasted, asked in the order that costs least. Ours first: it costs
  # no request to recognise, and neither the address parser nor a signed GET
  # should ever be pointed at this installation.
  defp classify_lookup(%User{} = user, url) do
    case local_lookup_post(url) do
      %Post{} = post ->
        {:local, post}

      nil ->
        cond do
          local_host?(url) -> {:error, :local_url}
          # An account rather than a post. `parse_address/1` is pure string work
          # and accepts exactly the three shapes people paste (`@you@server`,
          # `you@server`, `https://server/@you`); a post URL has a path segment
          # too many for any of them, so the two are told apart without asking
          # anybody anything.
          match?({:ok, _}, RemoteFollow.parse_address(url)) -> {:account, url}
          true -> look_up_remote_post(user, url)
        end
    end
  end

  @doc """
  Why this member cannot look a post up, when they cannot: `nil` when they can,
  else `:fediverse_disabled`, `:not_federating` or `:moved`.

  The render-time half of the gate `look_up_post/2` applies at submit, so the
  page can put the explanation and the switch where the form would be instead of
  letting somebody paste a URL into a box that was never going to work.
  """
  def lookup_refusal(%User{} = user) do
    case check_can_look_up(user) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  @doc "How many posts one member may look up by URL per hour."
  def lookup_limit, do: Application.get_env(:vutuv, :fediverse_lookup_limit, @lookup_limit)

  defp check_can_look_up(%User{} = user) do
    cond do
      not enabled?() -> {:error, :fediverse_disabled}
      not federated?(user) -> {:error, :not_federating}
      moved?(user) -> {:error, :moved}
      true -> :ok
    end
  end

  # A vutuv post URL. Matched on **host plus path**, not on a prefix of
  # `Endpoint.url()`: a member pastes what their browser or their mail client
  # gave them, and that is the same link in half a dozen spellings — the `www.`
  # alias, a trailing slash, a `?utm_source=` a share button appended, a
  # fragment, a shouted host, plain `http`. Every one of them named a post and
  # every one of them missed a whole-string prefix match, which sent an
  # unmistakably local link off to `look_up_remote_post/2`, where this
  # installation made a signed request to itself and spent a slot of the
  # member's hourly budget doing it.
  #
  # The **id** names the post; the handle in front of it is decoration that goes
  # stale the moment its owner renames, so the post is resolved by id alone and
  # the caller navigates to its current canonical path. `local_note_post/1` on
  # the boost path deliberately does require the pair to agree — but that one
  # decides whether a member's post may be **redistributed** on a remote actor's
  # say-so, where this only decides where to send a reader who is already here.
  # What they may see when they arrive is the permalink's own business.
  defp local_lookup_post(url) do
    with [_username, "posts", post_id] <- local_path(url),
         %Post{} = post <- UUIDv7.with_cast(post_id, &Repo.get(Post, &1)) do
      # With its author attached: the caller's next move is `Posts.path/1`.
      Repo.preload(post, :user)
    else
      _ -> nil
    end
  end

  defp look_up_remote_post(%User{} = user, url) do
    with :ok <- check_can_look_up(user),
         :ok <- check_lookup_url(url),
         {:ok, post} <- fetch_looked_up_post(user, url) do
      hold_looked_up_post(user, post)
      {:ok, Repo.preload(post, :remote_account)}
    end
  end

  # The pasted string, before anybody is asked anything: a real https URL on a
  # host the operator has not shut out. `https` only because that is what the
  # fetch below speaks — an `http://` link would fail there anyway, and saying
  # so here is a better answer than "that server did not respond".
  defp check_lookup_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        if instance_blocked?(url), do: {:error, :instance_blocked}, else: :ok

      _ ->
        {:error, :invalid_post_url}
    end
  end

  defp fetch_looked_up_post(%User{} = user, url) do
    case cached_lookup_post(url) do
      %RemotePost{} = post -> {:ok, post}
      nil -> dereference_looked_up_post(user, url)
    end
  end

  # A post we already hold, under either of the two URLs one post is written as.
  # The row is keyed on the canonical object id servers exchange
  # (`https://host/users/you/statuses/1`), but what a member pastes is almost
  # always the display URL they were reading (`https://host/@you/1`), which the
  # insert stores beside it. Matching both is what makes re-opening a post free.
  defp cached_lookup_post(url) do
    Repo.one(
      from(p in RemotePost,
        where: p.object_uri == ^url or p.origin_url == ^url,
        order_by: [asc: p.id],
        limit: 1
      )
    )
  end

  defp dereference_looked_up_post(%User{} = user, url) do
    with {:ok, key} <- lookup_signer(user),
         :ok <- claim_lookup_budget(user),
         {:ok, doc} <- fetch_lookup_document(url, key),
         {:ok, author_uri} <- lookup_author(url, doc),
         :ok <- check_lookup_hosts(doc, url, author_uri),
         {:ok, audience} <- lookup_audience(doc),
         {:ok, author} <- lookup_author_account(author_uri, key) do
      store_looked_up_post(author, doc, audience)
    end
  end

  # No key, no lookup — and `:not_federating` rather than a shrug, because a
  # federating member without an actor row is a member one click from having
  # one, and that click is what the refusal points at.
  defp lookup_signer(%User{} = user) do
    case signer(user) do
      nil -> {:error, :not_federating}
      key -> {:ok, key}
    end
  end

  defp claim_lookup_budget(%User{id: user_id}) do
    case RateLimiter.hit({:fediverse_lookup, user_id}, lookup_limit(), @inbound_window_ms) do
      :ok -> :ok
      _ -> {:error, :lookup_capped}
    end
  end

  # The same https-only, SSRF-fenced, size-capped, signed GET every other fetch
  # here makes, plus the object-type gate: a `Video`, an `Article` or an `Event`
  # with a `content` field is not a post, and neither is an actor document
  # somebody pasted the profile URL of.
  defp fetch_lookup_document(url, key) do
    case fetch_remote_note(url, key) do
      {:ok, doc} ->
        case remote_post_object(doc) do
          %{} = note -> {:ok, note}
          nil -> {:error, :not_a_post}
        end

      _unreachable ->
        {:error, :post_unreachable}
    end
  end

  # A server may only speak for itself, exactly as on the announce path: the
  # document is the object we asked for, its author lives on the object's own
  # host, and it does not claim to be one of ours. Without this, any server
  # could answer a URL on **its** host with a Note attributed to somebody else
  # entirely, and we would store that person's name over a stranger's words.
  defp lookup_author(url, doc) do
    author_uri = announced_author(doc)

    if is_binary(author_uri) and own_object?(url, doc, author_uri),
      do: {:ok, author_uri},
      else: {:error, :not_a_post}
  end

  # The blocklist on the other two hops. `own_object?/3` has already tied all
  # three to one host, so this can only fire together with the check on the
  # pasted URL — which is the point: the day that check changes, this one is
  # still asking the question the operator's block means.
  defp check_lookup_hosts(doc, url, author_uri) do
    object_id = SearchText.normalize_search(doc["id"]) || url

    if instance_blocked?(object_id) or instance_blocked?(author_uri),
      do: {:error, :instance_blocked},
      else: :ok
  end

  # Public and unlisted only. A member may well be able to read a followers-only
  # post on the origin server with their own account there, but they are not
  # reading it there — they are asking this installation to store a copy of it,
  # and an audience its author narrowed is not one we widen.
  defp lookup_audience(doc) do
    case announced_audience(doc) do
      audience when is_binary(audience) -> {:ok, audience}
      _narrower -> {:error, :post_not_public}
    end
  end

  defp lookup_author_account(author_uri, key) do
    case announced_author_account(author_uri, key) do
      %RemoteAccount{} = account -> {:ok, account}
      nil -> {:error, :post_unreachable}
    end
  end

  defp store_looked_up_post(%RemoteAccount{} = author, doc, audience) do
    case insert_remote_post(author, doc, audience) do
      {:ok, post} ->
        attach_pictures(post, doc)
        {:ok, post}

      # Another lookup (or a delivery) stored it while this one was fetching.
      # The row is what we wanted either way, and its pictures are that write's
      # business.
      {:exists, post} ->
        {:ok, post}

      _error ->
        {:error, :not_a_post}
    end
  end

  # The hold this feature owes the copy it leaves behind (see
  # `Vutuv.Fediverse.PostLookup`). Written for a cached post too, not only a
  # freshly fetched one: whoever looked it up first may unfollow tomorrow, and
  # the reader in front of us now is a reason of their own for it to stay.
  defp hold_looked_up_post(%User{id: user_id}, %RemotePost{id: post_id}) do
    %PostLookup{user_id: user_id, remote_post_id: post_id}
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :remote_post_id])

    :ok
  end

  ## Sharing one of their posts onward (issue #1166)

  @doc """
  Whether `user` may repost the cached post `post`, and when not, which gate
  refused. The `check_remote_post_reply/2` vocabulary, for the same reasons:

    * `:fediverse_disabled`, `:not_federating`, `:moved`, `:instance_blocked`,
      `:not_visible` — as everywhere else in this subsystem.
    * `:post_not_public` — a followers-only post. Passing on an audience its
      author deliberately narrowed is not ours to do, and a boost is the least
      reversible way to do it: it reaches everybody who follows the reposter,
      here and out there. So the control does not render, and this refuses if
      somebody reaches the event anyway.
  """
  def check_remote_repost(%User{} = user, %RemotePost{} = post),
    # Exactly the answer path's gate, and for the same reason: the audience
    # question first, because no setting of the member's could make a
    # followers-only post shareable, then everything the like path asks.
    do: check_remote_post_reply(user, post)

  # Claims one slot from the member's hourly repost budget.
  defp claim_boost_budget(%User{id: user_id}),
    do:
      claim_outbound_budget(
        user_id,
        :fediverse_outbound_boost,
        outbound_boost_limit(),
        :boost_capped
      )

  @doc "How many reposts per hour one member may send to other networks."
  def outbound_boost_limit,
    do: Application.get_env(:vutuv, :fediverse_outbound_boost_limit, @outbound_boost_limit)

  @doc """
  The member shares a cached post onward: writes the row and queues a signed
  `Announce` to their own followers (and the original author).

  `{:ok, :reposted}`, `{:ok, :already}`, or the gate's `{:error, reason}`. Like
  the heart, the post is re-read first: the row can be gone by the time the
  button is pressed, and the audience can have narrowed, and neither may be
  decided from the struct the page rendered with.
  """
  def repost_remote_post(%User{} = user, %RemotePost{} = post),
    do: with_feed_nudge(user, fn -> outbound_act(user, post, remote_post_repost()) end)

  @doc """
  The member takes the boost back: drops the row and queues the matching
  `Undo(Announce)`.

  No gate and no budget, like unliking — a withdrawal must not be refusable, and
  it must go out even once the member has stopped federating (issue #1102), which
  `deliver_boost/3` handles through `ever_federated?/1`.
  """
  def unrepost_remote_post(%User{} = user, %RemotePost{} = post),
    do: outbound_undo(user, post, remote_post_repost())

  @doc """
  Which of `post_ids` this member has reposted, as a `MapSet` — one query per
  feed page rather than one per card.
  """
  def reposted_remote_post_ids(%User{} = viewer, post_ids) when is_list(post_ids),
    do: marker_ids(PostRepost, :remote_post_id, viewer, post_ids)

  def reposted_remote_post_ids(_viewer, _post_ids), do: MapSet.new()

  # An Announce goes to the reposter's own audience — that is the act — plus the
  # original author, so their server learns of the boost. The one place this
  # differs from the like beside it (`deliver_like/3`), which is why the rest is
  # shared.
  # A boost is addressed exactly as loudly as what it boosts (`audience`), so
  # resharing an unlisted post never puts it into the public timelines its
  # author kept it out of.
  defp deliver_boost(user, %RemotePost{} = post, builder) do
    deliver_remote_activity(
      user,
      post,
      &builder.(&1, &2, &3, post.audience),
      fn account -> Enum.uniq(delivery_inboxes(user) ++ List.wrap(account.inbox_uri)) end
    )
  end

  ## Federating posts (called from Vutuv.Posts after commit)

  @doc "A freshly published post -> Create(Note) to every follower inbox."
  def federate_new_post(%Post{} = post) do
    # The author's own delivery decides what this function answers; the topics
    # carrying the post are a second, independent audience and must not change
    # what a caller reads about the first.
    result = maybe_federate(post, &Docs.create_activity/2, "post_create")
    announce_to_tag_followers(post)
    result
  end

  @doc """
  The topics a post carries announce it to **their** followers (issue #1330):
  somebody who followed `@elixir@tags.<host>` from their own server gets it,
  without an account here. A tag actor boosting a note is exactly an `Announce`,
  so it reuses the one the repost path already builds.

  Three gates, and each is load-bearing:

  - **The author must federate.** A tag actor announcing indiscriminately would
    carry out the posts of the very members who chose not to, which is why there
    is no per-tag opt-in and why this check cannot move.
  - **The post must be public.** `restricted?/1` is the same gate the author's
    own delivery passes; an audience the author narrowed must not widen because
    a topic was attached.
  - **Only the tags of a post published here.** A cached post from another
    server (`Vutuv.Fediverse.RemotePostTag`) never reaches this path, and must
    not: re-announcing it would be redistributing somebody else's content from
    our own actor.

  A topic nobody follows queues nothing, so the common case costs one query and
  no delivery.
  """
  def announce_to_tag_followers(%Post{} = post) do
    with true <- enabled?(),
         false <- Posts.restricted?(post),
         author when not is_nil(author) <- Posts.author(post),
         true <- federated?(author) do
      post |> announceable_tags() |> Enum.each(&announce_to_tag(&1, post, author))
      :ok
    else
      _ -> :skip
    end
  end

  # Both ways a post carries a tag — the composer's chips and a `#hashtag` in
  # the body — and canonical tags only: an alias is another name for a topic,
  # never a second actor announcing the same post twice.
  defp announceable_tags(%Post{id: post_id}) do
    Repo.all(
      from(t in Tag,
        where: is_nil(t.merged_into_id),
        where:
          t.id in subquery(
            from(pt in "post_tags",
              where: pt.post_id == type(^post_id, Vutuv.UUIDv7),
              select: pt.tag_id
            )
          ) or
            t.id in subquery(
              from(ph in "post_hashtags",
                where: ph.post_id == type(^post_id, Vutuv.UUIDv7),
                select: ph.tag_id
              )
            )
      )
    )
  end

  defp announce_to_tag(%Tag{} = tag, %Post{} = post, author) do
    case tag_follower_inboxes(tag) do
      [] ->
        :skip

      inboxes ->
        {:ok, _actor} = ensure_tag_actor(tag)
        enqueue(tag, inboxes, Docs.announce_activity(post, author, tag))
    end
  end

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

  # Nothing an organization publishes federates yet (issue #1334's fediverse half
  # is not built), and this is the one gate all three outbound paths share —
  # create, update and the unfreeze republish. Without it `Repo.get(User, nil)`
  # **raises** rather than answering nil, so unfreezing an organization post
  # would crash the moderation action rather than skip a delivery.
  # A page's post (issue #1334). The member branch below cannot serve it: it
  # loads a %User{} from `post.user_id`, and every gate it applies afterwards is
  # about an account. What a page needs instead is its own opt-in and its own
  # followers — and no `restricted?` check, because an organization post carries
  # no audience by construction.
  defp maybe_federate(%Post{organization_id: id} = post, builder, kind) when is_binary(id) do
    with true <- enabled?(),
         %Organization{} = page <- Organizations.get_organization(id),
         true <- federated?(page),
         post = Repo.preload(post, Docs.note_preloads()),
         [_ | _] = inboxes <- delivery_inboxes(page) do
      record_post_deliveries(page, post, inboxes)
      enqueue(page, inboxes, builder.(post, page), hold_opts(post, kind))
    else
      _ -> :skip
    end
  end

  defp maybe_federate(%Post{user_id: nil}, _builder, _kind), do: :skip

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
  # A post published in an organization's name (issue #1334) has never left the
  # building: organizations have no actor and no followers out there yet, so
  # there is nothing to ask anybody to forget. **Revisit this the moment they
  # federate** — this is the takedown chokepoint every path funnels through, so
  # a stale `:skip` here would mean "taken down here, still published there".
  def revoke_post(%Post{user_id: nil}), do: :skip

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

  # The page twin. Explicit rather than a cascade for the reason the column has
  # no foreign key: these rows outlive the post and its author on purpose.
  def drop_post_deliveries(%Organization{id: id}) do
    {count, _} = Repo.delete_all(from(d in PostDelivery, where: d.organization_id == ^id))
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

  # How many takedowns gave up without arriving.
  defp delivery_failure_count, do: Repo.aggregate(DeliveryFailure, :count)

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
  # Whether this post was ever addressed to an inbox. The rows are written at
  # enqueue time, so this says "we sent it somewhere", never "somebody received
  # it" — enough for the one question it answers (issue #1585), since a post that
  # was never enqueued has no remote copy to bring up to date.
  defp addressed_anywhere?(post_id),
    do: Repo.exists?(from(d in PostDelivery, where: d.post_id == ^post_id))

  defp fallback_targets(%User{} = user, %Post{} = post) do
    case recipients(user, post) do
      [] -> []
      inboxes -> [{Docs.note_url(user, post.id), inboxes}]
    end
  end

  defp record_post_deliveries(%Organization{} = page, %Post{} = post, inboxes) do
    record_post_deliveries(page, post, inboxes, organization_id: page.id)
  end

  defp record_post_deliveries(%User{} = user, %Post{} = post, inboxes) do
    record_post_deliveries(user, post, inboxes, user_id: user.id)
  end

  defp record_post_deliveries(sender, %Post{} = post, inboxes, owner) do
    object_uri = Docs.note_url(sender, post.id)
    stamp = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    rows =
      Enum.map(inboxes, fn inbox ->
        Enum.into(owner, %{
          id: UUIDv7.generate(),
          post_id: post.id,
          inbox_uri: inbox,
          object_uri: object_uri,
          inserted_at: stamp
        })
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
  How long a post with an unvetted picture waits before it looks again.

  A post's images are invisible until the AI scan releases them
  (`Vutuv.Moderation.ImageScans`), so a Note built the instant the post commits
  carries no attachment for them and nothing would ever send the picture. The
  post is therefore held, and released the moment the scan settles — usually a
  few seconds later, through `images_settled/1`.

  This is the **re-check interval**, not a ceiling (issue #1720): a post never
  federates with a picture the scan has not cleared, so when the verdict is slow
  the row simply goes back in the queue for another interval. It used to give up
  at this mark and send the post without its picture, which put the wait's outcome
  in the hands of whichever came first — that is what the mosaic made
  unnecessary, since readers *here* are no longer staring at a hole while the
  scan runs. Configurable (`:fediverse_image_hold_seconds`) so tests do not sit on
  a real clock.
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

  **Nothing queued any more means the scan came back too late** (issue #1585):
  the ceiling ran out, the `Create` went to the followers carrying no
  attachment, and its row was deleted on success. Nothing else ever revisits a
  post, so the picture would never arrive — the release therefore falls back to
  the `Update` an edit sends. That marks the remote copy as edited although the
  author changed nothing, which is much the smaller loss of the two.

  It is also the only thing that ever federates a **book review's cover**:
  `Vutuv.Posts.ReviewCovers` fetches that in a task *after* the post has
  committed, so the post is long gone by the time there is a cover to hold it
  for and `Posts.awaiting_image_release?/1` never held it at all.
  """
  def images_settled(post_id) when is_binary(post_id) do
    if enabled?() and not Posts.awaiting_image_release?(post_id) do
      # Asked before the release, so the Deliverer draining a row mid-call
      # cannot read as "nothing was queued" and earn the post a second
      # delivery. A row that is merely *due* has not been sent either, and it
      # re-renders with the picture at send time.
      #
      # Post-level, so a post still retrying one inbox while the others already
      # hold the attachment-less copy keeps the old behaviour for those. Closing
      # that needs the per-inbox reading `revoke_post/1` does.
      if Repo.exists?(held_deliveries(post_id)) do
        release_held_deliveries(post_id)
      else
        update_delivered_post(post_id)
      end
    end

    :ok
  end

  def images_settled(_post_id), do: :ok

  # Every queued delivery built from this post, whether or not it is due yet.
  defp held_deliveries(post_id) do
    markers = Enum.map(["post_create", "post_update"], &"#{&1}:#{post_id}")
    from(d in Delivery, where: d.rebuild_from in ^markers)
  end

  defp release_held_deliveries(post_id) do
    now = DateTime.utc_now(:second)

    {nudged, _} =
      post_id
      |> held_deliveries()
      |> where([d], d.next_attempt_at > ^now)
      |> Repo.update_all(set: [next_attempt_at: now])

    if nudged > 0, do: Deliverer.nudge()
    :ok
  end

  # A post deleted while the scanner thought about it has nothing to bring up to
  # date, and `federate_post_update/1` turns one whose audience closed in the
  # meantime into the revocation instead — both of which are why this goes
  # through the ordinary edit path rather than enqueueing an Update itself.
  defp update_delivered_post(post_id) do
    # `Repo.get/2` and not `Posts.get_post/1`: that one is the page-rendering
    # loader (10 queries — screenshots, verified links, the author) where
    # `maybe_federate/3` re-reads the author for itself and preloads exactly
    # what the Note needs. A bare struct also sends `Posts.restricted?/1` to its
    # forced-fresh clause, which is the reading we want for an audience that may
    # have closed while the scanner was thinking.
    with true <- addressed_anywhere?(post_id),
         %Post{} = post <- Repo.get(Post, post_id) do
      federate_post_update(post)
    end

    :ok
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
  def federate_repost(%Post{} = post, reposter),
    do: maybe_federate_repost(post, reposter, &Docs.announce_activity/3)

  @doc "The resharer takes it back -> `Undo(Announce)` with the matching id."
  def federate_unrepost(%Post{} = post, reposter),
    do: maybe_federate_repost(post, reposter, &Docs.undo_announce_activity/3)

  defp maybe_federate_repost(%Post{} = post, reposter, builder) do
    with true <- enabled?(),
         true <- federated?(reposter),
         false <- resharer_moved?(reposter),
         false <- Posts.restricted?(post),
         # `Posts.author/1`, never `Repo.get(User, post.user_id)`: that column is
         # NULL on a page's post and `Repo.get/2` RAISES on nil rather than
         # answering nothing. It only fired for a federated member resharing a
         # page's post, so it sat here unnoticed from the day pages could
         # publish (issue #1334).
         author when not is_nil(author) <- Posts.author(post),
         true <- federated?(author),
         [_ | _] = inboxes <- repost_inboxes(reposter) do
      enqueue(reposter, inboxes, builder.(post, author, reposter))
    else
      _ -> :skip
    end
  end

  # Only a member can have moved to another server; a page has no `moved_to`.
  defp resharer_moved?(%User{} = user), do: moved?(user)
  defp resharer_moved?(%Organization{}), do: false

  defp repost_inboxes(%User{} = user), do: delivery_inboxes(user)
  defp repost_inboxes(%Organization{} = page), do: delivery_inboxes(page)

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

  # The page twin (issue #1334). Not optional politeness: an unanswered Follow
  # shows on Mastodon as pending forever, which is exactly the "pressed Follow
  # and nothing happened" failure the opt-in gate exists to prevent.
  # `Docs.accept_activity/2` already names the right actor, because
  # `actor_url/1` knows both kinds.
  def accept_follow(%Organization{} = organization, follow_object, inbox_uri) do
    enqueue(organization, [inbox_uri], Docs.accept_activity(organization, follow_object))
  end

  # The topic twin (issue #1330), and the reason the delivery queue had to learn
  # a third owner in the same change: an inbox that records a Follow but cannot
  # answer it leaves the other side on "pending" forever.
  def accept_follow(%Tag{} = tag, follow_object, inbox_uri) do
    enqueue(tag, [inbox_uri], Docs.accept_activity(tag, follow_object))
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
          user_id: sender_column(user, :user),
          organization_id: sender_column(user, :organization),
          tag_id: sender_column(user, :tag),
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

  # Exactly one of the two sender columns is set, whichever kind was handed in.
  defp sender_column(%Organization{id: id}, :organization), do: id
  defp sender_column(%Organization{}, :user), do: nil
  defp sender_column(%User{id: id}, :user), do: id
  defp sender_column(%User{}, :organization), do: nil
  defp sender_column(%Tag{id: id}, :tag), do: id
  defp sender_column(_sender, :tag), do: nil
  defp sender_column(%Tag{}, _column), do: nil

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
          preload: [:user, :organization, :tag]
        )
      )

    # Load each sender's actor once — a burst of deliveries for one member (or
    # one page) all share the same actor row — instead of re-querying per
    # delivery. Two maps rather than one keyed on a mixed id, so a page and a
    # member can never collide on a lookup.
    actors = actors_by_user_id(due)
    organization_actors = actors_by_organization_id(due)
    tag_actors = actors_by_tag_id(due)

    due
    |> Task.async_stream(&attempt(&1, signing_actor(&1, actors, organization_actors, tag_actors)),
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

  defp actors_by_organization_id(rows) do
    ids = rows |> Enum.map(& &1.organization_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(a in Actor, where: a.organization_id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.organization_id, &1})
  end

  defp actors_by_tag_id(rows) do
    ids = rows |> Enum.map(& &1.tag_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(a in Actor, where: a.tag_id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.tag_id, &1})
  end

  defp signing_actor(%Delivery{organization_id: id}, _actors, organization_actors, _tag_actors)
       when is_binary(id),
       do: organization_actors[id]

  defp signing_actor(%Delivery{tag_id: id}, _actors, _organization_actors, tag_actors)
       when is_binary(id),
       do: tag_actors[id]

  defp signing_actor(%Delivery{user_id: id}, actors, _organization_actors, _tag_actors),
    do: actors[id]

  # A page's delivery (issue #1334). Same guards as a member's — https, no
  # internal address, not a blocked instance — minus `rebuilt/2`: that re-renders
  # a held post, and the only thing a page sends today is an `Accept`, which has
  # nothing to rebuild. When a page publishes (F5) this grows the same branch.
  defp attempt(%Delivery{organization: %Organization{} = organization} = delivery, actor) do
    with %Actor{} = actor <- actor,
         %URI{scheme: "https", host: host} <- URI.parse(delivery.inbox_uri),
         false <- Vutuv.Ssrf.resolves_to_internal?(host),
         false <- instance_blocked?(delivery.inbox_uri) do
      post_activity(delivery, organization, actor)
    else
      _ -> Repo.delete(delivery)
    end
  end

  # A topic's delivery (issue #1330). Same guards as the page's, and like it no
  # `rebuilt/2`: a tag actor sends an `Accept`, which has nothing to re-render.
  defp attempt(%Delivery{tag: %Tag{} = tag} = delivery, actor) do
    with %Actor{} = actor <- actor,
         %URI{scheme: "https", host: host} <- URI.parse(delivery.inbox_uri),
         false <- Vutuv.Ssrf.resolves_to_internal?(host),
         false <- instance_blocked?(delivery.inbox_uri) do
      post_activity(delivery, tag, actor)
    else
      _ -> Repo.delete(delivery)
    end
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
      # Still waiting on a picture: put the row back rather than send the post
      # without it (issue #1720).
      :hold ->
        repark(delivery)

      # No key, a non-https inbox, an internal target, a blocked server, or a
      # post that is gone or no longer public: undeliverable for good, so the row
      # goes instead of clogging the queue.
      _ ->
        Repo.delete(delivery)
    end
  end

  defp attempt(%Delivery{} = delivery, _actor), do: Repo.delete(delivery)

  # A held row re-renders its activity now, so a picture the AI scan released
  # while it waited rides along (issue #1070) — or reparks itself, when the
  # scan is still out (issue #1720).
  defp rebuilt(%Delivery{rebuild_from: nil} = delivery, _user), do: {:ok, delivery}

  defp rebuilt(%Delivery{rebuild_from: marker} = delivery, user) do
    with [kind, post_id] <- String.split(marker, ":", parts: 2),
         builder when is_function(builder) <- rebuild_builder(kind) do
      # The cheap question first, and outside the `with`. Cheap, because a
      # reparked row asks it again every interval for as long as the scan is
      # out, and `Posts.get_post/1` below is some twenty preloads: reading the
      # post plus its images and review is three. Outside, because two boolean
      # steps in one chain both fail with `true` — an else-clause reading
      # `true -> :hold` would catch the closed-audience case as well and repark
      # a delivery that must never go out, for ever, which is precisely the
      # immortal row `repark/1` exists to avoid.
      if Posts.awaiting_image_release?(post_id) do
        :hold
      else
        rebuild_now(delivery, builder, post_id, user)
      end
    else
      _ -> :drop
    end
  end

  # The gates are re-checked here rather than when the row was queued: the post
  # may have been deleted or had its audience closed during the hold, and then
  # this delivery must not go out at all.
  defp rebuild_now(delivery, builder, post_id, user) do
    with %Post{} = post <- Posts.get_post(post_id),
         false <- Posts.restricted?(post) do
      post = Repo.preload(post, Docs.note_preloads())
      {:ok, %{delivery | activity_json: Jason.encode!(builder.(post, user))}}
    else
      _ -> :drop
    end
  end

  # A post whose picture the AI scan has not judged yet goes back in the queue
  # for another `image_hold_seconds/0` instead of travelling without it (issue
  # #1720). Two things this must not do, and both are the reason it exists at
  # all rather than a longer initial delay:
  #
  #   * **not count an attempt.** These are not failures — nothing was sent —
  #     and eight of them would retire the row at `@max_attempts` and lose the
  #     post for good.
  #   * **not leave `next_attempt_at` where it is.** A due row that stays due
  #     is picked up by every drain, holds the front of the queue and spends
  #     the batch on work that cannot complete (the sweeper deadlock of #1316).
  #
  # `images_settled/1` is what normally ends the wait, within seconds; this is
  # the fallback that makes the wait survive a lost broadcast, a crash between
  # verdict and release, and a scanner that is down for hours.
  defp repark(%Delivery{} = delivery) do
    delivery
    |> Ecto.Changeset.change(
      next_attempt_at: DateTime.add(DateTime.utc_now(:second), image_hold_seconds())
    )
    |> Repo.update()
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

  defp ap_get(url, signer, etag \\ nil) do
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
              conditional_header(etag) ++
              [{"accept", "application/activity+json"}, {"user-agent", Http.user_agent()}],
          receive_timeout: 8_000,
          connect_options: [timeout: 2_000],
          retry: false,
          redirect: false,
          # The callers `Jason.decode` the body themselves, so Req's own decode
          # step must stay off — `into:` does NOT imply that. Today only the
          # MIME registry's ignorance of `application/activity+json` keeps the
          # body a binary; a server answering plain `application/json` (spec
          # legal) would arrive decoded and fail the `is_binary` path.
          decode_body: false,
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

  # Only the counts refresher has an ETag to send; every other fetch here asks
  # unconditionally, because it wants the document rather than a "still the
  # same".
  defp conditional_header(etag) when is_binary(etag) and etag != "",
    do: [{"if-none-match", etag}]

  defp conditional_header(_none), do: []
end
