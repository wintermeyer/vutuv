defmodule VutuvWeb.FediverseController do
  @moduledoc """
  The ActivityPub surface of follow-only federation (`Vutuv.Fediverse`):

    * `GET /.well-known/webfinger` — how Mastodon's search turns
      `@handle@host` into an actor URL,
    * `GET /:slug/actor` (+ `/followers`, `/outbox`) — the member's
      machine-readable identity,
    * `POST /:slug/actor/inbox` — receives signed `Follow`/`Undo` activities
      plus the remote actor's own lifecycle (`Update` re-syncs the stored
      follower, `Delete` of the actor removes it); everything else is
      acknowledged and dropped (outbound-only by design).

  Deliberately outside the `:browser` pipeline: no session, no CSRF — remote
  servers authenticate with HTTP signatures instead, verified against the
  key of the actor named in the signature's `keyId` (fetched SSRF-guarded).
  Everything 404s for members without the opt-in and while the installation
  switch (`:fediverse_enabled`) is off.
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
         %User{} = user <- resolve_resource(params["resource"]),
         true <- Fediverse.federated?(user) do
      conn
      |> put_resp_content_type("application/jrd+json")
      |> send_resp(200, Jason.encode!(jrd(user)))
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

  def inbox(conn, %{"slug" => slug}) do
    with_federated_user(conn, slug, fn user ->
      cond do
        # The operator's kill switch (issue #1067), checked FIRST: before the
        # signature is verified, before the remote actor document is fetched
        # (an outbound request to a host we refuse to talk to) and before any
        # write. Answered 202 like every other dropped activity, never 403, so
        # the blocklist cannot be enumerated from outside.
        blocked_sender?(conn) ->
          send_resp(conn, 202, "")

        VutuvWeb.RateLimit.check(conn, :fediverse_inbox, nil,
          limit: 300,
          window_ms: :timer.hours(1)
        ) == :rate_limited ->
          send_resp(conn, 429, "")

        true ->
          verify_and_perform(conn, user)
      end
    end)
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
  defp verify_and_perform(conn, user) do
    activity = conn.body_params

    with {:ok, key_id} <- signature_key_id(conn),
         {:ok, remote} <- Fediverse.fetch_remote_actor(key_id, signer(user)),
         true <- same_authority?(key_id, remote.id),
         :ok <- verify_signature(conn, remote),
         true <- activity["actor"] == remote.id do
      perform(conn, user, activity, remote)
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

  defp perform(conn, user, %{"type" => "Follow"} = activity, remote) do
    if activity["object"] == Docs.actor_url(user) do
      # A remote actor doc with an over-long / malformed inbox or id yields an
      # invalid changeset; accept only a successful insert, never crash the inbox.
      case Fediverse.add_follower(user, follower_attrs(remote)) do
        {:ok, _} -> Fediverse.accept_follow(user, activity, remote.inbox)
        {:error, _} -> :ok
      end
    end

    send_resp(conn, 202, "")
  end

  defp perform(conn, user, %{"type" => "Undo", "object" => %{"type" => "Follow"}}, remote) do
    Fediverse.remove_follower(user, remote.id)
    send_resp(conn, 202, "")
  end

  # Somebody on another network favourited (`Like`) or re-shared (`Announce`)
  # one of the member's public posts (issue #1068). Stored as a bare counter
  # row — no name, no text, no picture — so the member sees that their post
  # travelled. Every gate lives in `Fediverse.record_reaction/4`; whatever it
  # decides, the answer is the same 202, so a misdirected activity never tells
  # the sender which of the conditions it failed.
  defp perform(conn, user, %{"type" => type, "object" => object}, remote)
       when type in ["Like", "Announce"] do
    Fediverse.record_reaction(user, object, reaction_kind(type), remote.id)
    send_resp(conn, 202, "")
  end

  # The remote side took its reaction back. Honoured at once: an upstream
  # withdrawal is the deletion path that makes storing the row defensible.
  defp perform(
         conn,
         user,
         %{"type" => "Undo", "object" => %{"type" => type} = undone},
         remote
       )
       when type in ["Like", "Announce"] do
    Fediverse.remove_reaction(user, undone["object"], reaction_kind(type), remote.id)
    send_resp(conn, 202, "")
  end

  # A remote actor that renamed or moved its inbox broadcasts an `Update` of
  # itself to everyone following it. Re-sync from the actor document we just
  # fetched: the row is both a delivery target and what the member sees on
  # their Fediverse settings page, so a stale copy shows the wrong handle and
  # can deliver to the wrong inbox. An `Update` of anything else (a remote
  # note) falls through to the catch-all.
  defp perform(conn, user, %{"type" => "Update"} = activity, remote) do
    if object_id(activity["object"]) == remote.id do
      Fediverse.refresh_follower(user, follower_attrs(remote))
    end

    send_resp(conn, 202, "")
  end

  # A remote account deleting itself tells every server that follows it, so
  # drop the row instead of keeping a gone account as a follower (and as a
  # delivery target). Only a `Delete` of the *actor* counts — deleting one of
  # its notes must leave the follow intact. Best effort by construction: a
  # server that already purged the account answers our actor fetch with 410,
  # so the signature can no longer be verified and `verify_and_perform/2`
  # rejects it; this catches the window where the account is suspended but
  # still served, which is when most servers send the Delete.
  defp perform(conn, user, %{"type" => "Delete"} = activity, remote) do
    if object_id(activity["object"]) == remote.id do
      Fediverse.remove_follower(user, remote.id)
    end

    send_resp(conn, 202, "")
  end

  # Outbound-only federation: likes, replies, announces etc. are acknowledged
  # (so well-behaved servers stop retrying) and dropped.
  defp perform(conn, _user, _activity, _remote), do: send_resp(conn, 202, "")

  defp reaction_kind("Like"), do: "like"
  defp reaction_kind("Announce"), do: "announce"

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
  # GETs.
  defp signer(user) do
    case Fediverse.get_actor(user) do
      nil -> nil
      actor -> {Docs.key_id(user), actor.private_key_pem}
    end
  end

  defp with_federated_user(conn, slug, fun) do
    with true <- Fediverse.enabled?(),
         %User{} = user <- Accounts.get_user_by_username(slug),
         true <- Fediverse.federated?(user) do
      fun.(user)
    else
      _ -> send_resp(conn, 404, "")
    end
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
