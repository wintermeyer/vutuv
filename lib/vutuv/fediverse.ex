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
      kept in step with the remote's own Update/Delete.
    * deliveries — a DB-backed outbound queue (`Vutuv.Fediverse.Delivery`)
      drained by `Vutuv.Fediverse.Deliverer` with signed POSTs
      (`Vutuv.Fediverse.HttpSignature`), mirroring the webhooks queue.

  Everything sits behind the global `:fediverse_enabled` switch
  (FEDIVERSE_ENABLED, for installations that must not call out — intranets)
  and behind the per-member opt-in: consent first, because deletion of
  federated copies on remote servers is not enforceable.
  """

  import Ecto.Query
  import Vutuv.Moderation.Query, only: [account_hidden_row: 1]

  require Logger

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse.Actor
  alias Vutuv.Fediverse.Deliverer
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.Follower
  alias Vutuv.Fediverse.HttpSignature
  alias Vutuv.Fediverse.Keys
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostDenial
  alias Vutuv.Repo
  alias Vutuv.SocialFeed.Http
  alias VutuvWeb.Fediverse.Docs

  @max_attempts 8
  @max_body_bytes 500_000

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

  @doc """
  Records a remote follower (idempotent per remote actor). A repeat Follow
  re-syncs every cached field from the actor document, the display ones
  included — a remote who renamed must not stay listed under the old handle.
  """
  def add_follower(%User{} = user, attrs) do
    %Follower{user_id: user.id}
    |> Follower.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:inbox_uri, :shared_inbox_uri, :handle, :name, :updated_at]},
      conflict_target: [:user_id, :actor_uri]
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

  @doc """
  Installation-wide federation figures for the admin dashboard (issue #843):
  how many members federate, how many remote followers they have between them,
  the outbound delivery-queue depth and how many of those rows are stuck
  (carry a `last_error`), so a broken delivery run is visible at a glance.
  """
  def stats do
    %{
      federating_members: federating_member_count(),
      remote_followers: Repo.aggregate(Follower, :count),
      queue_depth: Repo.aggregate(Delivery, :count),
      stuck_deliveries:
        Repo.aggregate(from(d in Delivery, where: not is_nil(d.last_error)), :count)
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
  defp signer(user) do
    case get_actor(user) do
      nil -> nil
      actor -> {Docs.key_id(user), actor.private_key_pem}
    end
  end

  ## Federating posts (called from Vutuv.Posts after commit)

  @doc "A freshly published post -> Create(Note) to every follower inbox."
  def federate_new_post(%Post{} = post), do: maybe_federate(post, &Docs.create_activity/2)

  @doc """
  An edited post -> Update(Note); one whose audience closed -> Delete, so
  remote copies follow the post out of public view (best effort — remote
  deletion is advisory by protocol).
  """
  def federate_post_update(%Post{} = post) do
    if Vutuv.Posts.restricted?(post) do
      federate_post_delete(post)
    else
      maybe_federate(post, &Docs.update_activity/2)
    end
  end

  @doc "A deleted post -> Delete(Tombstone) (best effort)."
  def federate_post_delete(%Post{id: post_id, user_id: user_id}) do
    with true <- enabled?(),
         %User{} = user <- Repo.get(User, user_id),
         true <- federated?(user),
         false <- moved?(user),
         [_ | _] = inboxes <- delivery_inboxes(user) do
      enqueue(user, inboxes, Docs.delete_activity(post_id, user))
    else
      _ -> :skip
    end
  end

  defp maybe_federate(%Post{} = post, builder) do
    with true <- enabled?(),
         %User{} = user <- Repo.get(User, post.user_id),
         true <- federated?(user),
         false <- moved?(user),
         false <- Vutuv.Posts.restricted?(post),
         [_ | _] = inboxes <- delivery_inboxes(user) do
      post = Repo.preload(post, [:images, :review, reply_ref: [:parent_author]])
      enqueue(user, inboxes, builder.(post, user))
    else
      _ -> :skip
    end
  end

  @doc "Answers a Follow with Accept, straight to the follower's own inbox."
  def accept_follow(%User{} = user, follow_object, inbox_uri) do
    enqueue(user, [inbox_uri], Docs.accept_activity(user, follow_object))
  end

  defp enqueue(user, inboxes, activity) do
    json = Jason.encode!(activity)
    now = DateTime.utc_now(:second)
    stamp = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    rows =
      Enum.map(inboxes, fn inbox ->
        %{
          id: Vutuv.UUIDv7.generate(),
          user_id: user.id,
          inbox_uri: inbox,
          activity_json: json,
          attempts: 0,
          next_attempt_at: now,
          inserted_at: stamp,
          updated_at: stamp
        }
      end)

    Repo.insert_all(Delivery, rows)
    Deliverer.nudge()
    :ok
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

  defp actors_by_user_id(deliveries) do
    user_ids = deliveries |> Enum.map(& &1.user_id) |> Enum.uniq()

    from(a in Actor, where: a.user_id in ^user_ids)
    |> Repo.all()
    |> Map.new(&{&1.user_id, &1})
  end

  defp attempt(%Delivery{user: %User{} = user} = delivery, actor) do
    with %Actor{} = actor <- actor,
         %URI{scheme: "https", host: host} <- URI.parse(delivery.inbox_uri),
         false <- Vutuv.Ssrf.resolves_to_internal?(host) do
      post_activity(delivery, user, actor)
    else
      # No key, a non-https inbox or an internal target: undeliverable for
      # good, so the row goes instead of clogging the queue.
      _ -> Repo.delete(delivery)
    end
  end

  defp attempt(%Delivery{} = delivery, _actor), do: Repo.delete(delivery)

  defp post_activity(delivery, user, actor) do
    body = delivery.activity_json

    headers =
      HttpSignature.signed_headers(
        "post",
        delivery.inbox_uri,
        body,
        Docs.key_id(user),
        actor.private_key_pem
      ) ++
        [{"content-type", "application/activity+json"}, {"user-agent", Http.user_agent()}]

    options =
      Keyword.merge(
        [
          url: delivery.inbox_uri,
          body: body,
          headers: headers,
          receive_timeout: 10_000,
          connect_options: [timeout: 2_000],
          retry: false,
          redirect: false
        ],
        Application.get_env(:vutuv, :fediverse_req_options, [])
      )

    case Req.post(options) do
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

  defp fail(%Delivery{attempts: attempts} = delivery, error) when attempts + 1 >= @max_attempts do
    Logger.info("fediverse delivery to #{delivery.inbox_uri} gave up: #{error}")
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
