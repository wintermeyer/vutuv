defmodule VutuvWeb.FediverseController do
  @moduledoc """
  The ActivityPub surface of follow-only federation (`Vutuv.Fediverse`):

    * `GET /.well-known/webfinger` — how Mastodon's search turns
      `@handle@host` into an actor URL,
    * `GET /:slug/actor` (+ `/followers`, `/outbox`) — the member's
      machine-readable identity,
    * `POST /:slug/actor/inbox` — receives signed `Follow`/`Undo` activities;
      everything else is acknowledged and dropped (outbound-only by design).

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
      case VutuvWeb.RateLimit.check(conn, :fediverse_inbox, nil,
             limit: 300,
             window_ms: :timer.hours(1)
           ) do
        :ok -> verify_and_perform(conn, user)
        :rate_limited -> send_resp(conn, 429, "")
      end
    end)
  end

  # The signature names the sender (keyId -> actor document -> public key).
  # The activity's actor must be that same actor, or anyone could sign a
  # Follow as themselves while claiming to be someone else.
  defp verify_and_perform(conn, user) do
    activity = conn.body_params

    with {:ok, key_id} <- signature_key_id(conn),
         {:ok, remote} <- Fediverse.fetch_remote_actor(key_id, signer(user)),
         :ok <- verify_signature(conn, remote),
         true <- activity["actor"] == remote.id do
      perform(conn, user, activity, remote)
    else
      _ -> send_resp(conn, 401, "")
    end
  end

  defp perform(conn, user, %{"type" => "Follow"} = activity, remote) do
    if activity["object"] == Docs.actor_url(user) do
      {:ok, _} =
        Fediverse.add_follower(user, %{
          actor_uri: remote.id,
          inbox_uri: remote.inbox,
          shared_inbox_uri: remote.shared_inbox
        })

      Fediverse.accept_follow(user, activity, remote.inbox)
    end

    send_resp(conn, 202, "")
  end

  defp perform(conn, user, %{"type" => "Undo", "object" => %{"type" => "Follow"}}, remote) do
    Fediverse.remove_follower(user, remote.id)
    send_resp(conn, 202, "")
  end

  # Outbound-only federation: likes, replies, announces etc. are acknowledged
  # (so well-behaved servers stop retrying) and dropped.
  defp perform(conn, _user, _activity, _remote), do: send_resp(conn, 202, "")

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
