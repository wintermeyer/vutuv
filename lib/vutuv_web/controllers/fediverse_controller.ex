defmodule VutuvWeb.FediverseController do
  @moduledoc """
  The ActivityPub surface of follow-only federation (`Vutuv.Fediverse`):

    * `GET /.well-known/webfinger` — how Mastodon's search turns
      `@handle@host` into an actor URL,
    * `GET /:slug/actor` (+ `/followers`, `/outbox`,
      `/collections/featured` — the pinned post, issue #1110) — the member's
      machine-readable identity,
    * `POST /:slug/actor/inbox` — receives signed `Follow`/`Undo` activities,
      the reactions and replies other networks send back (`Like`/`Announce`,
      issue #1068; `Create(Note)`, issues #1069 and #1071, plus the author's own
      `Update`/`Delete` of such a note) and the remote actor's own lifecycle
      (`Update` re-syncs the stored follower, `Delete` of the actor removes it);
      everything else is acknowledged and dropped,
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
  alias VutuvWeb.Fediverse.Docs
  alias VutuvWeb.RawBodyReader

  @activity_json "application/activity+json"

  @doc "Whether the client asked for the ActivityPub representation."
  def ap_request?(conn) do
    accept = conn |> get_req_header("accept") |> Enum.join(",")
    accept =~ @activity_json or accept =~ "application/ld+json"
  end

  def webfinger(conn, params) do
    with true <- Fediverse.enabled?(),
         %User{} = user <- resolve_resource(params["resource"]) do
      if Fediverse.federated?(user) do
        conn
        |> put_resp_content_type("application/jrd+json")
        |> send_resp(200, Jason.encode!(jrd(user)))
      else
        refuse(conn, user)
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
      send_activity_json(conn, %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => Docs.actor_url(user) <> "/followers",
        "type" => "OrderedCollection",
        "totalItems" => Fediverse.follower_count(user)
      })
    end)
  end

  def outbox(conn, %{"slug" => slug}) do
    with_federated_user(conn, slug, fn user ->
      send_activity_json(conn, %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => Docs.actor_url(user) <> "/outbox",
        "type" => "OrderedCollection",
        "totalItems" => Fediverse.public_post_count(user)
      })
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
  # `users` is who the activity is for: exactly one member at the per-member
  # inbox, whoever the activity addressed at the shared one — where it may also
  # be nobody, which is still verified first and only then dropped, so an
  # unsigned delivery is a 401 whatever it claims to be addressed to.
  defp verify_and_perform(conn, users) do
    activity = conn.body_params

    with {:ok, key_id} <- signature_key_id(conn),
         {:ok, remote} <- Fediverse.fetch_remote_actor(key_id, signer(users)),
         true <- same_authority?(key_id, remote.id),
         :ok <- verify_signature(conn, remote),
         true <- activity["actor"] == remote.id do
      Enum.each(users, &perform(&1, activity, remote))
      send_resp(conn, 202, "")
    else
      _ -> send_resp(conn, 401, "")
    end
  end

  # The signing keyId must be served by the same host as the actor id it names.
  # Without this an attacker-controlled host can serve a key document claiming
  # `id: "https://good.example/alice"`, spoofing Follow/Undo as any actor.
  defp same_authority?(key_id, actor_id) when is_binary(key_id) and is_binary(actor_id) do
    key_host = URI.parse(key_id).host
    not is_nil(key_host) and key_host == URI.parse(actor_id).host
  end

  defp same_authority?(_key_id, _actor_id), do: false

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
    Fediverse.record_reaction(user, object, reaction_kind(type), reacting_actor(remote))
    :ok
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
    Fediverse.record_reply(user, activity, remote_author(remote))
    :ok
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
    else
      # Not the actor: the author is withdrawing a note they wrote under one of
      # our members' posts. Honoured at once and unconditionally — an upstream
      # withdrawal is the deletion path that makes storing their words
      # defensible, so it must not depend on any switch still being on.
      Fediverse.delete_reply(remote.id, object_id(activity["object"]))
    end

    :ok
  end

  # Outbound-only federation: likes, replies, announces etc. are acknowledged
  # (so well-behaved servers stop retrying) and dropped.
  defp perform(_user, _activity, _remote), do: :ok

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

  # Remote-actor fetches are signed with the followed member's own key —
  # instances running in authorized-fetch ("secure") mode reject anonymous
  # GETs. At the shared inbox that is the first addressee we resolved; a
  # delivery addressed to nobody here falls back to an anonymous fetch, which
  # such an instance may refuse — and then the delivery is rejected, which is
  # the right outcome for an activity that was for none of our members anyway.
  defp signer([%User{} = user | _rest]) do
    case Fediverse.get_actor(user) do
      nil -> nil
      actor -> {Docs.key_id(user), actor.private_key_pem}
    end
  end

  defp signer([]), do: nil

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
    |> put_resp_content_type(@activity_json)
    |> send_resp(200, Jason.encode!(doc))
  end

  # acct:handle@host (the WebFinger form Mastodon uses), or the profile /
  # actor URL pasted directly.
  defp resolve_resource("acct:" <> acct) do
    with [handle, host] <- String.split(acct, "@", parts: 2),
         true <- host == VutuvWeb.Endpoint.host() do
      Accounts.get_user_by_username(String.downcase(handle))
    else
      _ -> nil
    end
  end

  defp resolve_resource(url) when is_binary(url) do
    base = String.trim_trailing(VutuvWeb.Endpoint.url(), "/") <> "/"

    case String.replace_prefix(url, base, "") do
      ^url -> nil
      rest -> rest |> String.trim_trailing("/actor") |> Accounts.get_user_by_username()
    end
  end

  defp resolve_resource(_), do: nil

  defp jrd(user) do
    profile_url = "#{String.trim_trailing(VutuvWeb.Endpoint.url(), "/")}/#{user.username}"

    %{
      "subject" => "acct:#{user.username}@#{VutuvWeb.Endpoint.host()}",
      "aliases" => [profile_url, Docs.actor_url(user)],
      "links" => [
        %{"rel" => "self", "type" => @activity_json, "href" => Docs.actor_url(user)},
        %{
          "rel" => "http://webfinger.net/rel/profile-page",
          "type" => "text/html",
          "href" => profile_url
        }
      ]
    }
  end
end
