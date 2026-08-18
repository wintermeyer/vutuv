defmodule VutuvWeb.FediverseController do
  @moduledoc """
  The ActivityPub surface of follow-only federation (`Vutuv.Fediverse`):

    * `GET /.well-known/webfinger` — how Mastodon's search turns
      `@handle@host` into an actor URL,
    * `GET /:slug/actor` (+ `/followers`, `/following`, `/outbox`,
      `/collections/featured` — the pinned post, issue #1110) — the member's
      machine-readable identity,
    * `POST /:slug/actor/inbox` — receives signed `Follow`/`Undo` activities,
      the `Accept`/`Reject` answering a Follow the member sent out (issue
      #1160), the reactions and replies other networks send back
      (`Like`/`Announce`, issue #1068; `Create(Note)`, issues #1069 and #1071,
      plus the author's own `Update`/`Delete` of such a note) and the remote
      actor's own lifecycle (`Update` re-syncs the stored follower and the
      stored account, `Delete` of the actor removes both); everything else is
      acknowledged and dropped,
    * `POST /system/inbox` — the same handling once for the whole installation
      (issue #1073), so a server with many followers here delivers a broadcast
      once and it is fanned out to every member the activity addresses.

  Deliberately outside the `:browser` pipeline: no session, no CSRF — remote
  servers authenticate with HTTP signatures instead, verified against the
  key of the actor named in the signature's `keyId` (fetched SSRF-guarded).
  Everything 404s for members without the opt-in and while the installation
  switch (`:fediverse_enabled`) is off — except for a member who took part and
  then switched it off, whose actor answers `410 Gone` so remote servers delete
  their copies (see `refuse/2`).
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.HttpSignature
  alias Vutuv.Handles
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
  alias VutuvWeb.Fediverse.Docs
  alias VutuvWeb.RawBodyReader

  @activity_json "application/activity+json"

  @doc "Whether the client asked for the ActivityPub representation."
  def ap_request?(conn) do
    accept = conn |> get_req_header("accept") |> Enum.join(",")
    accept =~ @activity_json or accept =~ "application/ld+json"
  end

  # A person with a browser rather than another server, asked on the tag host,
  # where the two want the same URL to answer differently.
  #
  # Deliberately not `not ap_request?(conn)`: a fetch carrying `*/*`, or no
  # Accept at all, is far likelier to be a server than a reader, and of the two
  # ways to be wrong here only one is silent. A reader handed the actor
  # document sees JSON and shrugs; a remote server handed a redirect stops
  # being able to follow the topic, and nothing would say so.
  defp browser_request?(conn) do
    conn.method == "GET" and
      conn |> get_req_header("accept") |> Enum.join(",") =~ "text/html"
  end

  def webfinger(conn, params) do
    with true <- Fediverse.enabled?(),
         subject when not is_nil(subject) <- resolve_resource(params["resource"]) do
      if Fediverse.federated?(subject) do
        conn
        |> put_resp_content_type("application/jrd+json")
        |> send_resp(200, Jason.encode!(jrd(subject)))
      else
        refuse(conn, subject)
      end
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  def actor(conn, %{"slug" => slug}) do
    with_federated_user(conn, slug, fn user ->
      {:ok, actor} = Fediverse.ensure_actor(user)

      send_activity_json(conn, Docs.actor(user, actor))
    end)
  end

  def followers(conn, %{"slug" => slug}) do
    with_federated_user(conn, slug, fn user ->
      send_activity_json(
        conn,
        Docs.count_collection(Docs.followers_url(user), Fediverse.follower_count(user))
      )
    end)
  end

  # The accounts the member follows out there (issue #1160), count-only for the
  # same reason the followers collection is: who somebody reads is theirs to
  # know. Only **accepted** follows are counted — a request nobody answered is
  # not a relationship, and publishing it would leak what a member tried to do.
  def following(conn, %{"slug" => slug}) do
    with_federated_user(conn, slug, fn user ->
      send_activity_json(
        conn,
        Docs.count_collection(Docs.following_url(user), Fediverse.accepted_follow_count(user))
      )
    end)
  end

  def outbox(conn, %{"slug" => slug}) do
    with_federated_user(conn, slug, fn user ->
      send_activity_json(
        conn,
        Docs.count_collection(Docs.outbox_url(user), Fediverse.public_post_count(user))
      )
    end)
  end

  # The pinned post (issue #1110), the collection Mastodon and friends read to
  # show a pin at the top of the profile they render. Strictly the **anonymous
  # public** view — a pin that is restricted, frozen or otherwise not public is
  # simply not in it, exactly as it is absent from the agent formats.
  def featured(conn, %{"slug" => slug}) do
    with_federated_user(conn, slug, fn user ->
      send_activity_json(conn, Docs.featured_collection(user, Fediverse.featured_posts(user)))
    end)
  end

  def inbox(conn, %{"slug" => slug}) do
    with_federated_user(conn, slug, fn user ->
      guarded(conn, fn -> verify_and_perform(conn, [user]) end)
    end)
  end

  @doc """
  The installation-wide inbox (issue #1073, `VutuvWeb.Fediverse.Docs.shared_inbox_url/0`):
  one endpoint a remote server can deliver a broadcast to **once** instead of
  once per member it touches here — the efficiency we already take advantage of
  when we deliver outward through a remote's own sharedInbox.

  Everything about it is the per-member inbox: the same installation switch, the
  same operator blocklist checked first, the same per-IP limit, the same
  signature and anti-spoofing verification, and then the very same handling per
  member. The only difference is where the addressees come from — the activity
  instead of the URL (`Vutuv.Fediverse.inbox_recipients/2`).

  Two deliberate asymmetries:

    * it never answers `404`/`410`. Those belong to a URL that names one member,
      where a `410` is how a server learns *that account* is gone; here every
      accepted delivery is a `202`, so the endpoint cannot be used to ask
      whether a given member takes part.
    * the actor fetch that verification needs is signed with the key of the
      first addressee we resolved from the still-unverified body (the per-member
      inbox uses the addressed member's key). It only ever picks a member the
      sender itself named, and the fetch goes back to the sender's own host.
  """
  def shared_inbox(conn, _params) do
    if Fediverse.enabled?() do
      activity = conn.body_params

      guarded(conn, fn ->
        verify_and_perform(conn, Fediverse.inbox_recipients(activity, activity["actor"]))
      end)
    else
      send_resp(conn, 404, "")
    end
  end

  # The operator's kill switch (issue #1067) is checked FIRST: before the
  # signature is verified, before the remote actor document is fetched (an
  # outbound request to a host we refuse to talk to) and before any write.
  # Answered 202 like every other dropped activity, never 403, so the blocklist
  # cannot be enumerated from outside.
  defp guarded(conn, fun) do
    cond do
      blocked_sender?(conn) ->
        send_resp(conn, 202, "")

      VutuvWeb.RateLimit.check(conn, :fediverse_inbox, nil,
        limit: 300,
        window_ms: :timer.hours(1)
      ) == :rate_limited ->
        send_resp(conn, 429, "")

      true ->
        fun.()
    end
  end

  # Both names the request offers for its sender: the signature's `keyId` (whose
  # host we would otherwise fetch the actor document from) and the activity's
  # claimed `actor`. Neither is verified yet, so a match on *either* is enough —
  # a blocked server must not be able to talk its way in by lying about one.
  defp blocked_sender?(conn) do
    key_id =
      case signature_key_id(conn) do
        {:ok, key_id} -> key_id
        _ -> nil
      end

    [key_id, conn.body_params["actor"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(&Fediverse.instance_blocked?/1)
  end

  # The signature names the sender (keyId -> actor document -> public key).
  # The activity's actor must be that same actor, or anyone could sign a
  # Follow as themselves while claiming to be someone else.
  #
  # `recipients` is who the activity is for: exactly one member at the
  # per-member inbox, whoever the activity addressed at the shared one — where it
  # may be a member, a page or a topic, several of them, or nobody at all, which
  # is still verified first and only then dropped, so an unsigned delivery is a
  # 401 whatever it claims to be addressed to.
  defp verify_and_perform(conn, recipients) do
    activity = conn.body_params

    with {:ok, key_id} <- signature_key_id(conn),
         {:ok, remote} <- Fediverse.fetch_remote_actor(key_id, signer(recipients)),
         # The signing keyId must be served by the same host as the actor id it
         # names — without this an attacker-controlled host can serve a key
         # document claiming `id: "https://good.example/alice"`, spoofing
         # Follow/Undo as any actor. `Fediverse.same_host?/2` is the one
         # spelling of that predicate (it also guards an actor's inbox) and
         # additionally pins the keyId to https and refuses an empty host.
         true <- Fediverse.same_host?(remote.id, key_id),
         :ok <- verify_signature(conn, remote),
         true <- activity["actor"] == remote.id do
      Enum.each(recipients, &perform_for_recipient(&1, activity, remote))
      perform_once(activity, remote)
      send_resp(conn, 202, "")
    else
      _ -> send_resp(conn, 401, "")
    end
  end

  # One addressee of a shared-inbox delivery, whichever kind of actor it is. The
  # three `perform*` families below are the per-kind handlers the three
  # per-actor inboxes already run; this is the only place that has to know all
  # three exist, and it is what a delivery to `endpoints.sharedInbox` — which
  # every actor document of ours advertises — needs in order to reach a page or a
  # topic at all.
  defp perform_for_recipient(%User{} = user, activity, remote),
    do: perform(user, activity, remote)

  defp perform_for_recipient(%Organization{} = organization, activity, remote),
    do: perform_for_organization(organization, activity, remote)

  defp perform_for_recipient(%Tag{} = tag, activity, remote),
    do: perform_for_tag(tag, activity, remote)

  # What one addressed member does with an activity. Deliberately returns
  # nothing the caller uses: the answer is the same 202 whatever any of these
  # decide, and at the shared inbox one delivery runs this once per addressee.
  defp perform(user, %{"type" => "Follow"} = activity, remote) do
    if activity["object"] == Docs.actor_url(user) do
      # A remote actor doc with an over-long / malformed inbox or id yields an
      # invalid changeset; accept only a successful insert, never crash the inbox.
      case Fediverse.add_follower(user, follower_attrs(remote)) do
        {:ok, _} -> Fediverse.accept_follow(user, activity, remote.inbox)
        {:error, _} -> :ok
      end
    end

    :ok
  end

  defp perform(user, %{"type" => "Undo", "object" => %{"type" => "Follow"}}, remote) do
    Fediverse.remove_follower(user, remote.id)
    :ok
  end

  # The answer to a Follow the member sent out (issue #1160). `Accept` seals it,
  # `Reject` removes the row. Both are scoped inside the context to the actor
  # that answered, so one server can never settle a follow addressed to another.
  defp perform(user, %{"type" => "Accept"} = activity, remote) do
    Fediverse.accept_remote_follow(user, activity, remote.id)
    :ok
  end

  defp perform(user, %{"type" => "Reject"} = activity, remote) do
    Fediverse.reject_remote_follow(user, activity, remote.id)
    :ok
  end

  # Somebody on another network favourited (`Like`) or re-shared (`Announce`)
  # one of the member's public posts (issue #1068). Stored as their account
  # address and what they did — no display name, no text, no picture — so the
  # member sees that their post travelled and by whom. The handle rides along
  # from the actor document this request already fetched to check the
  # signature, so naming them costs no second request. Every gate lives in
  # `Fediverse.record_reaction/4`; whatever it decides, the answer is the same
  # 202, so a misdirected activity never tells the sender which of the
  # conditions it failed.
  defp perform(user, %{"type" => type, "object" => object}, remote)
       when type in ["Like", "Announce"] do
    user
    |> Fediverse.record_reaction(object, reaction_kind(type), reacting_actor(remote))
    |> remember_actor_if_stored(remote)
  end

  # The remote side took its reaction back. Honoured at once: an upstream
  # withdrawal is the deletion path that makes storing the row defensible.
  defp perform(user, %{"type" => "Undo", "object" => %{"type" => type} = undone}, remote)
       when type in ["Like", "Announce"] do
    Fediverse.remove_reaction(user, undone["object"], reaction_kind(type), remote.id)
    :ok
  end

  # Somebody on another network answered one of the member's posts (issues
  # #1069 and #1071). Every gate lives in `Fediverse.record_reply/3` — the
  # member's separate opt-in among them — and the answer is the same 202
  # whatever it decides, so a misdirected activity never learns which gate it
  # failed.
  defp perform(user, %{"type" => "Create"} = activity, remote) do
    user
    |> Fediverse.record_reply(activity, remote_author(remote))
    |> remember_actor_if_stored(remote)
  end

  # A remote actor that renamed or moved its inbox broadcasts an `Update` of
  # itself to everyone following it. Re-sync from the actor document we just
  # fetched: the row is both a delivery target and what the member sees on
  # their Fediverse settings page, so a stale copy shows the wrong handle and
  # can deliver to the wrong inbox.
  #
  # An `Update` of anything else is an author editing a note they sent us, which
  # is honoured too — including a narrowed audience, which is the same "stop
  # showing this" signal a 403 carries.
  defp perform(user, %{"type" => "Update"} = activity, remote) do
    if object_id(activity["object"]) == remote.id do
      Fediverse.refresh_follower(user, follower_attrs(remote))
      # The same document also keeps the account a member here follows current
      # (issue #1160): a renamed account must not stay listed under the old
      # handle on either page. Installation-wide, not per member — one row backs
      # every follow of it.
      Fediverse.refresh_remote_account(remote)
    else
      Fediverse.update_reply(user, activity, remote.id)
    end

    :ok
  end

  # A remote account deleting itself tells every server that follows it, so
  # drop the row instead of keeping a gone account as a follower (and as a
  # delivery target). Only a `Delete` of the *actor* counts — deleting one of
  # its notes must leave the follow intact. Best effort by construction: a
  # server that already purged the account answers our actor fetch with 410,
  # so the signature can no longer be verified and `verify_and_perform/2`
  # rejects it; this catches the window where the account is suspended but
  # still served, which is when most servers send the Delete.
  defp perform(user, %{"type" => "Delete"} = activity, remote) do
    if object_id(activity["object"]) == remote.id do
      Fediverse.remove_follower(user, remote.id)
      # And in the other direction (issue #1160): an account that deleted itself
      # is nothing anybody here can go on following, so the stored account (and
      # with it every follow of it) goes too.
      Fediverse.remove_remote_account(remote.id)
    else
      # Not the actor: the author is withdrawing a note they wrote under one of
      # our members' posts. Honoured at once and unconditionally — an upstream
      # withdrawal is the deletion path that makes storing their words
      # defensible, so it must not depend on any switch still being on.
      Fediverse.delete_reply(remote.id, object_id(activity["object"]))
    end

    :ok
  end

  # Everything else is acknowledged (so well-behaved servers stop retrying) and
  # dropped.
  defp perform(_user, _activity, _remote), do: :ok

  # What a delivery does **once**, whoever it was addressed to (issue #1161).
  #
  # A post by an account members here follow is one post, not one per follower:
  # several members can follow the same account, and until every server uses our
  # shared inbox the same `Create` arrives once per follower. So the cache is
  # installation-wide and keyed on the post's own id, and it is written here
  # rather than inside `perform/3` — which runs per addressed member — so the
  # work happens once per delivery instead of once per reader.
  #
  # Deliberately narrow: only the author's own stream. A `Create` that answers a
  # member's post is the per-member `record_reply/3` above, and the gates in
  # `Fediverse.record_remote_post/2` refuse anything else.
  defp perform_once(%{"type" => "Create"} = activity, remote),
    do: Fediverse.record_remote_post(activity, remote.id)

  # A followed account re-sharing somebody else's post (issue #1167). Once per
  # delivery, like the `Create` above and for the same reason: there is one
  # cached row and one boost row behind it however many members here follow the
  # sender, so doing it per addressed member would be N identical writes and N
  # identical dereferences of a third server's post.
  #
  # The two are not exclusive and both run: an `Announce` naming a **member's
  # own** post is also the reaction path in `perform/3` above, which is what
  # tells the author their post travelled, while this one is what puts it in
  # the booster's followers' feeds. Everything else used to fall through
  # entirely.
  defp perform_once(%{"type" => "Announce"} = activity, remote),
    do: Fediverse.record_remote_boost(activity, remote.id)

  # A followed account telling its followers it moved (issue #1168). Once per
  # delivery: the swap is per member but the verification of the successor is
  # one fetch, and every member following this account gets re-pointed by the
  # same call.
  defp perform_once(%{"type" => "Move"} = activity, remote),
    do: Fediverse.record_remote_move(activity, remote.id)

  # A followed account taking a boost back (issue #1167). Once per delivery for
  # the same reason the Announce is: one boost row, however many followers. The
  # whole `Undo` goes through, because the row is named by the id of the
  # `Announce` it wraps.
  # An embedded `Announce` is what most implementations wrap, but some send the
  # bare activity URI instead. Both reach the context, which reads the id off
  # either shape — matching only the embedded map made the string form fall
  # through to the catch-all, leaving that boost standing forever.
  defp perform_once(%{"type" => "Undo", "object" => object} = activity, remote)
       when is_binary(object) or is_map_key(object, "type"),
       do: Fediverse.remove_remote_boost(activity, remote.id)

  # An author editing or withdrawing a post of theirs we cached. Both are
  # scoped to that author inside the context, so one server cannot rewrite or
  # delete another's; the `Delete` arm is deliberately ungated, because an
  # author taking their words back is what makes storing them defensible.
  defp perform_once(%{"type" => type} = activity, remote) when type in ~w(Update Delete) do
    case object_id(activity["object"]) do
      # The actor's own lifecycle — a renamed account, a deleted one — which is
      # per-member business and belongs to `perform/3` above, not to the cache.
      object_uri when object_uri == remote.id -> :ok
      _object_uri when type == "Update" -> Fediverse.update_remote_post(activity, remote.id)
      object_uri -> Fediverse.delete_remote_post(remote.id, object_uri)
    end
  end

  defp perform_once(_activity, _remote), do: :ok

  # Takes the outcome of `record_reaction/4` / `record_reply/3` and remembers
  # the actor only when something was really stored (`Fediverse.remember_remote_account/1`):
  # a stranger's activity that every gate refused must not be able to plant an
  # account row.
  defp remember_actor_if_stored(:ok, remote) do
    Fediverse.remember_remote_account(remote)
    :ok
  end

  defp remember_actor_if_stored(_skipped, _remote), do: :ok

  defp reaction_kind("Like"), do: "like"
  defp reaction_kind("Announce"), do: "announce"

  # What a stored reply keeps about its author: the actor URI (the takedown and
  # dedupe key), the two cosmetic display strings, and the inbox an answer goes
  # to (issue #1070 — we hold the verified actor document right here, so keeping
  # its inbox spares the reply path a network call). No avatar — the card
  # renders initials and links out, so vutuv never hosts a third party's
  # picture.
  # A reaction keeps the account address alone: the URI and the same address in
  # the `@handle@host` notation. Deliberately not `remote_author/1` — a
  # favourite is not a text somebody wrote, so their display name has no job
  # here.
  defp reacting_actor(remote) do
    %{uri: remote.id, handle: remote.preferred_username}
  end

  defp remote_author(remote) do
    %{
      uri: remote.id,
      handle: remote.preferred_username,
      name: remote.name,
      inbox: remote.inbox
    }
  end

  defp follower_attrs(remote) do
    %{
      actor_uri: remote.id,
      inbox_uri: remote.inbox,
      shared_inbox_uri: remote.shared_inbox,
      handle: remote.preferred_username,
      name: remote.name
    }
  end

  # An activity's object is either an embedded document or a bare id URI.
  defp object_id(%{"id" => id}) when is_binary(id), do: id
  defp object_id(id) when is_binary(id), do: id
  defp object_id(_), do: nil

  defp signature_key_id(conn) do
    conn |> get_req_header("signature") |> List.first() |> HttpSignature.key_id()
  end

  defp verify_signature(conn, remote) do
    # Bandit surfaces the Host header in req_headers; put_new covers servers
    # (and test conns) that only carry it on the conn struct.
    headers = conn.req_headers |> Map.new() |> Map.put_new("host", conn.host)

    HttpSignature.valid?(
      %{
        method: "post",
        path: conn.request_path,
        headers: headers,
        body: RawBodyReader.raw_body(conn)
      },
      remote.public_key_pem
    )
  end

  # Remote-actor fetches are signed with the addressed actor's own key —
  # instances running in authorized-fetch ("secure") mode reject anonymous
  # GETs. At the shared inbox that is the first addressee we resolved, of
  # whichever kind: a page's delivery has to be signable by the page, or an
  # authorized-fetch server's answer to a reply under its post could not be
  # verified and the reply would be lost. A delivery addressed to nobody here
  # falls back to an anonymous fetch, which such an instance may refuse — and
  # then the delivery is rejected, which is the right outcome for an activity
  # that was for none of our actors anyway.
  defp signer([%Tag{} = tag | _rest]), do: tag_signer(tag)
  defp signer([subject | _rest]), do: Fediverse.signer(subject)
  defp signer([]), do: nil

  @doc """
  A page's actor document (issue #1334). 404s for a page that has not opted in,
  exactly as a member's does — which is what lets every piece of this half land
  on its own without being visible to another server first.
  """
  def organization_actor(conn, %{"slug" => slug}) do
    with_federated_organization(conn, slug, fn organization ->
      {:ok, actor} = Fediverse.ensure_actor(organization)

      send_activity_json(conn, Docs.organization_actor(organization, actor))
    end)
  end

  @doc "The page's followers collection — count only, like a member's."
  def organization_followers(conn, %{"slug" => slug}) do
    with_federated_organization(conn, slug, fn organization ->
      send_activity_json(
        conn,
        Docs.count_collection(
          Docs.actor_url(organization) <> "/followers",
          Fediverse.follower_count(organization)
        )
      )
    end)
  end

  @doc """
  A topic's actor document, served on the tag host (issue #1330).

  Minted on first ask, like a page's: a keypair is cheap and a topic nobody has
  ever looked up needs none. An **alias** answers 404 — it is another name for a
  topic, not a second address for the same posts.
  """
  def tag_actor(conn, %{"slug" => slug}) do
    with_federated_tag(conn, slug, fn tag ->
      {:ok, actor} = Fediverse.ensure_tag_actor(tag)

      send_activity_json(conn, Docs.tag_actor(tag, actor))
    end)
  end

  @doc "How many accounts out there follow this topic. Count only, like the rest."
  def tag_followers(conn, %{"slug" => slug}) do
    with_federated_tag(conn, slug, fn tag ->
      send_activity_json(
        conn,
        Docs.count_collection(
          Docs.actor_url(tag) <> "/followers",
          Fediverse.tag_remote_follower_count(tag)
        )
      )
    end)
  end

  @doc """
  The topic's outbox, empty for now.

  Advertised because the actor document names it and a document that names a
  collection which 404s reads as a broken actor from outside. What a topic
  sends is `Announce`, and that is the next slice.
  """
  def tag_outbox(conn, %{"slug" => slug}) do
    with_federated_tag(conn, slug, fn tag ->
      send_activity_json(conn, Docs.count_collection(Docs.actor_url(tag) <> "/outbox", 0))
    end)
  end

  @doc """
  The topic's inbox: `Follow` and `Undo(Follow)`, and nothing else.

  Narrower than a page's, which is already narrow. A topic holds no
  conversation, follows nobody and migrates nowhere, so `Like`, `Announce`,
  `Create`, `Accept` and `Move` have nothing to act on here and are
  acknowledged with the same `202` the other inboxes give what they do not
  handle.
  """
  def tag_inbox(conn, %{"slug" => slug}) do
    with_federated_tag(conn, slug, fn tag ->
      guarded(conn, fn -> verify_and_perform_for_tag(conn, tag) end)
    end)
  end

  defp verify_and_perform_for_tag(conn, tag) do
    activity = conn.body_params

    with {:ok, key_id} <- signature_key_id(conn),
         {:ok, remote} <- Fediverse.fetch_remote_actor(key_id, tag_signer(tag)),
         true <- Fediverse.same_host?(remote.id, key_id),
         :ok <- verify_signature(conn, remote),
         true <- activity["actor"] == remote.id do
      perform_for_tag(tag, activity, remote)
      send_resp(conn, 202, "")
    else
      _ -> send_resp(conn, 401, "")
    end
  end

  defp perform_for_tag(tag, %{"type" => "Follow"} = activity, remote) do
    # The object must be THIS topic's actor: a signed Follow naming somebody
    # else's actor is not a follow of this topic, whoever delivered it here.
    if activity["object"] == Docs.actor_url(tag) do
      case Fediverse.add_tag_follower(tag, follower_attrs(remote)) do
        {:ok, _} -> Fediverse.accept_follow(tag, activity, remote.inbox)
        {:error, _} -> :ok
      end
    end

    :ok
  end

  defp perform_for_tag(tag, %{"type" => "Undo", "object" => %{"type" => "Follow"}}, remote) do
    Fediverse.remove_tag_follower(tag, remote.id)
    :ok
  end

  defp perform_for_tag(_tag, _activity, _remote), do: :ok

  # A topic signs with its own key, the same shape the page's fetch uses.
  defp tag_signer(tag) do
    case Fediverse.ensure_tag_actor(tag) do
      {:ok, actor} -> {Docs.actor_url(tag) <> "#main-key", actor.private_key_pem}
      _ -> nil
    end
  end

  # A topic is federated when the installation is and the tag is a topic rather
  # than another name for one. There is no per-tag switch: nobody's content is
  # published by a tag actor existing, because what it announces is filtered by
  # each author's own opt-in at announce time.
  # Every tag-host action passes through here, which makes it the one place for
  # the question that comes before "which topic is this": is this a reader? The
  # tag host publishes actors and nothing a person reads, so they leave for the
  # site — see `leave_tag_host/2`.
  defp with_federated_tag(conn, slug, fun) do
    if browser_request?(conn),
      do: leave_tag_host(conn, slug),
      else: with_tag_actor(conn, slug, fun)
  end

  defp with_tag_actor(conn, slug, fun) do
    case Tags.get_canonical_tag_by_slug(slug) do
      nil -> send_resp(conn, 404, "")
      tag -> if Fediverse.federated?(tag), do: fun.(tag), else: send_resp(conn, 404, "")
    end
  end

  # The way off the tag host for a reader. A slug that names a topic goes to
  # that topic's page — following an alternative name, the same courtesy the
  # tag page's own 301 does — so somebody who clicked `@elixir@tags.<host>` in
  # another network's timeline lands on the topic they clicked instead of on a
  # start page they then have to search from.
  #
  # 301 for a topic, because that mapping does not change. 302 for the rest: an
  # unclaimed word names the start page only until somebody creates the tag,
  # and a permanent redirect a browser had cached would keep the reader from
  # ever reaching it.
  defp leave_tag_host(conn, slug) do
    case Tags.resolve_tag_by_slug(slug) do
      %Tag{} = tag -> redirect_to_site(conn, :moved_permanently, ~p"/tags/#{tag.slug}")
      nil -> redirect_to_site(conn, :found, "/")
    end
  end

  defp redirect_to_site(conn, status, path) do
    conn
    # This URL answers a reader and a remote server differently, so anything
    # caching it has to key on the Accept header rather than on the URL alone.
    |> put_resp_header("vary", "accept")
    |> put_status(status)
    |> redirect(external: String.trim_trailing(VutuvWeb.Endpoint.url(), "/") <> path)
  end

  @doc """
  A page's inbox (issue #1334): signed `Follow` and `Undo(Follow)` addressed to
  the page.

  Since #1336's last point it also takes the `Accept`/`Reject` answering a
  Follow the page itself sent.

  Still narrower than the member inbox. A page has no conversations, no
  reactions of its own to receive and no account migration, so `Like`,
  `Announce`, `Create(Note)` and `Move` have nothing to act
  on here — they are acknowledged with the same `202` and dropped, which is what
  the member inbox does with anything it does not handle either. That keeps the
  surface a page exposes to strangers as small as what it actually offers.
  """
  def organization_inbox(conn, %{"slug" => slug}) do
    with_federated_organization(conn, slug, fn organization ->
      guarded(conn, fn -> verify_and_perform_for_organization(conn, organization) end)
    end)
  end

  # The member path's `verify_and_perform/2` shape, with the page as the signer
  # for the actor fetch and the page's own two handlers after it. Verification
  # itself is identical — same signature check, same keyId/actor host pinning,
  # same refusal to trust an `actor` the signature does not cover.
  defp verify_and_perform_for_organization(conn, organization) do
    activity = conn.body_params

    with {:ok, key_id} <- signature_key_id(conn),
         {:ok, remote} <- Fediverse.fetch_remote_actor(key_id, Fediverse.signer(organization)),
         true <- Fediverse.same_host?(remote.id, key_id),
         :ok <- verify_signature(conn, remote),
         true <- activity["actor"] == remote.id do
      perform_for_organization(organization, activity, remote)
      send_resp(conn, 202, "")
    else
      _ -> send_resp(conn, 401, "")
    end
  end

  defp perform_for_organization(organization, %{"type" => "Follow"} = activity, remote) do
    # The object must be THIS page's actor: a signed Follow naming somebody
    # else's actor is not a follow of this page, whoever delivered it here.
    if activity["object"] == Docs.actor_url(organization) do
      case Fediverse.add_organization_follower(organization, follower_attrs(remote)) do
        {:ok, _} -> Fediverse.accept_follow(organization, activity, remote.inbox)
        {:error, _} -> :ok
      end
    end

    :ok
  end

  defp perform_for_organization(
         organization,
         %{"type" => "Undo", "object" => %{"type" => "Follow"}},
         remote
       ) do
    Fediverse.remove_organization_follower(organization, remote.id)
    :ok
  end

  # The answer to a Follow the PAGE sent out (issue #1336's last point). Only
  # meaningful since a page can follow at all; before that these fell into the
  # "acknowledged and dropped" clause below, and leaving them there now would
  # strand every request the page makes on "asked" forever.
  defp perform_for_organization(organization, %{"type" => "Accept"} = activity, remote) do
    Fediverse.accept_organization_remote_follow(organization, activity, remote.id)
    :ok
  end

  defp perform_for_organization(organization, %{"type" => "Reject"} = activity, remote) do
    Fediverse.reject_organization_remote_follow(organization, activity, remote.id)
    :ok
  end

  # Somebody on another network favourited or re-shared one of the page's posts
  # (issue #1334, completing #1068 for pages). Without this a page publishes
  # outward and learns nothing back: its post could travel and the team would
  # see a flat zero.
  defp perform_for_organization(organization, %{"type" => kind} = activity, remote)
       when kind in ["Like", "Announce"] do
    Fediverse.record_organization_reaction(
      organization,
      activity["object"],
      String.downcase(kind),
      %{uri: remote.id, handle: remote.preferred_username}
    )

    :ok
  end

  defp perform_for_organization(
         organization,
         %{"type" => "Undo", "object" => %{"type" => kind} = object},
         remote
       )
       when kind in ["Like", "Announce"] do
    Fediverse.remove_reaction(
      organization,
      object["object"],
      String.downcase(kind),
      remote.id
    )

    :ok
  end

  # Somebody on another network answered one of the page's posts (issue #1334,
  # completing #1069 for pages). Stored under the same retention model as a
  # member's: the text expires unless its origin keeps confirming it, and the
  # takedown ledger can reach it.
  defp perform_for_organization(organization, %{"type" => "Create"} = activity, remote) do
    Fediverse.record_organization_reply(organization, activity, %{
      uri: remote.id,
      handle: remote.preferred_username,
      name: remote.name,
      inbox: remote.inbox
    })

    :ok
  end

  # Everything else: acknowledged and dropped, like the member inbox.
  defp perform_for_organization(_organization, _activity, _remote), do: :ok

  @doc """
  The page's outbox, count-only like a member's.

  It exists because the actor document names it. An actor that advertises an
  endpoint answering 404 is not merely untidy — a remote server fetches the
  outbox while building its picture of an account, and a page whose own document
  points at nothing reads as broken from outside. This shipped that way for one
  commit; the check is now part of the test.
  """
  def organization_outbox(conn, %{"slug" => slug}) do
    with_federated_organization(conn, slug, fn organization ->
      send_activity_json(
        conn,
        Docs.count_collection(
          Docs.actor_url(organization) <> "/outbox",
          Fediverse.organization_public_post_count(organization)
        )
      )
    end)
  end

  defp with_federated_organization(conn, slug, fun) do
    with true <- Fediverse.enabled?(),
         %Organization{} = organization <- Organizations.get_organization_by_slug(slug) do
      if Fediverse.federated?(organization),
        do: fun.(organization),
        else: send_resp(conn, 404, "")
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  defp with_federated_user(conn, slug, fun) do
    with true <- Fediverse.enabled?(),
         %User{} = user <- Accounts.get_user_by_username(slug) do
      if Fediverse.federated?(user), do: fun.(user), else: refuse(conn, user)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  @doc """
  The refusal for an actor we will not serve: `410 Gone` once the member has
  switched their opt-in off (`Vutuv.Fediverse.departed?/1`), `404` otherwise.

  The distinction is the whole point rather than protocol pedantry: a remote
  server that meets a `410` on an actor it knows deletes that account **and the
  copies it kept of their posts**, which is the closest the protocol comes to
  honouring "forget me"; a `404` it shrugs off and keeps everything. So the
  `410` is reserved for the member's own decision to leave, and every temporary
  reason we hide an actor (frozen, suspended, deactivated, or the installation
  switch being off) keeps answering `404`.

  Public because the profile URL answers the same two ways under an ActivityPub
  `Accept` (`VutuvWeb.UserController`).
  """
  def refuse(conn, user) do
    if Fediverse.departed?(user),
      do: send_resp(conn, 410, ""),
      else: send_resp(conn, 404, "")
  end

  defp send_activity_json(conn, doc) do
    conn
    # Several of these URLs are the same one a reader opens (a profile, a post
    # permalink, a topic's address on the tag host) and answer by the Accept
    # header, so a cache that keyed on the URL alone would hand one client the
    # other's answer.
    |> put_resp_header("vary", "accept")
    |> put_resp_content_type(@activity_json)
    |> send_resp(200, Jason.encode!(doc))
  end

  # acct:handle@host (the WebFinger form Mastodon uses), or the profile /
  # actor URL pasted directly.
  #
  # Read tolerantly, because the asking server writes this string and not all of
  # them write it the way Mastodon does: a leading `@` on the handle is common,
  # and a host is a DNS name, so its case carries no meaning. A 404 here
  # dead-ends the whole remote-follow flow before it starts, and none of the
  # accepted spellings is ambiguous about who is meant.
  defp resolve_resource("acct:" <> acct) do
    case acct |> String.trim_leading("@") |> String.split("@", parts: 2) do
      [name, host] -> resolve_acct(name, host)
      _ -> nil
    end
  end

  defp resolve_resource(url) when is_binary(url) do
    # `https://host/@handle` is the profile URL Mastodon itself shows, so it is
    # what somebody pastes; the trailing slash a browser adds falls away in
    # `local_path/1`, which also accepts the `www.`/`http` spellings.
    case Fediverse.local_path(url) do
      [handle] -> by_handle(Handles.normalize(handle))
      [handle, "actor"] -> by_handle(Handles.normalize(handle))
      # The page's own URLs, which is what somebody pastes after finding it on
      # this site rather than through search.
      ["organizations", slug] -> Organizations.get_organization_by_slug(slug)
      ["organizations", slug, "actor"] -> Organizations.get_organization_by_slug(slug)
      _ -> nil
    end
  end

  defp resolve_resource(_), do: nil

  # Two WebFinger authorities on one installation (issue #1330). The tag host is
  # asked first because it is the narrower question: on `tags.<host>` an address
  # names a topic and nothing else, while the main host is where members and
  # pages share a namespace. `local_host?/1` folds case, port and the `www.`
  # alias — somebody pastes whatever spelling their browser showed them
  # (issue #1211) — and `tag_host?/1` does the same for its own host.
  defp resolve_acct(name, host) do
    cond do
      Fediverse.tag_host?(host) -> Tags.get_canonical_tag_by_slug(name)
      Fediverse.local_host?(host) -> by_handle(Handles.normalize(name))
      true -> nil
    end
  end

  # Members and pages share one handle namespace (issue #941), so a handle
  # resolves to at most one of them and the order is a fast path, not a
  # precedence rule.
  defp by_handle(handle) do
    Accounts.get_user_by_username(handle) || Organizations.get_organization_by_username(handle)
  end

  # A page's JRD (issue #1334). Shorter than a member's by two links: no
  # `subscribe` template, because that is where a *member* confirms a follow
  # they started elsewhere, and a page starts none.
  defp jrd(%Organization{} = organization) do
    # `canonical_path/1`, not the slug shape spelled out: a page that claimed a
    # root handle is served at that handle everywhere else, and this document is
    # what remote servers are told to show a human.
    page_url =
      String.trim_trailing(VutuvWeb.Endpoint.url(), "/") <>
        Organizations.canonical_path(organization)

    %{
      "subject" => "acct:" <> Docs.acct(organization),
      "aliases" => [page_url, Docs.actor_url(organization)],
      "links" => [
        %{"rel" => "self", "type" => @activity_json, "href" => Docs.actor_url(organization)},
        %{
          "rel" => "http://webfinger.net/rel/profile-page",
          "type" => "text/html",
          "href" => page_url
        }
      ]
    }
  end

  defp jrd(%Tag{} = tag) do
    # The `self` link is the actor on the tag host; the human link is the tag
    # page on the main host, which is where a reader wants to land.
    page_url = String.trim_trailing(VutuvWeb.Endpoint.url(), "/") <> "/tags/#{tag.slug}"

    %{
      "subject" => "acct:" <> Docs.acct(tag),
      "aliases" => [page_url, Docs.actor_url(tag)],
      "links" => [
        %{"rel" => "self", "type" => @activity_json, "href" => Docs.actor_url(tag)},
        %{
          "rel" => "http://webfinger.net/rel/profile-page",
          "type" => "text/html",
          "href" => page_url
        }
      ]
    }
  end

  defp jrd(user) do
    base = String.trim_trailing(VutuvWeb.Endpoint.url(), "/")
    profile_url = "#{base}/#{user.username}"

    %{
      "subject" => "acct:" <> Docs.acct(user),
      "aliases" => [profile_url, Docs.actor_url(user)],
      "links" => [
        %{"rel" => "self", "type" => @activity_json, "href" => Docs.actor_url(user)},
        %{
          "rel" => "http://webfinger.net/rel/profile-page",
          "type" => "text/html",
          "href" => profile_url
        },
        # Where this member confirms a follow they started on somebody else's
        # server (`VutuvWeb.AuthorizeInteractionController`). Without this link
        # a remote server has to guess: Mastodon guesses exactly this path, but
        # others simply tell the visitor that vutuv offers no follow dialog. The
        # `{uri}` placeholder is the object they were looking at and must stay
        # unencoded — the other server fills it in.
        %{
          "rel" => "http://ostatus.org/schema/1.0/subscribe",
          "template" => "#{base}/authorize_interaction?uri={uri}"
        }
      ]
    }
  end
end
