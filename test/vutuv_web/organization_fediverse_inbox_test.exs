defmodule VutuvWeb.OrganizationFediverseInboxTest do
  @moduledoc """
  A page's inbox (issue #1334) — the piece that makes discovery honest. Without
  it a page could be found and followed and the follow would sit pending
  forever, which is worse than not being findable at all.

  Deliberately narrower than the member inbox: a page receives `Follow` and
  `Undo(Follow)` and acknowledges everything else. It holds no conversations,
  answers no Follow of its own and does not migrate accounts, so those handlers
  would have nothing to act on.

  `async: false` because remote-actor fetching is stubbed through the
  application env, and the organization helpers flip the DNS-verification flag.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.HttpSignature
  alias Vutuv.Fediverse.Keys
  alias Vutuv.Repo
  alias VutuvWeb.Fediverse.Docs

  @remote_actor "https://social.example/users/alice"
  @remote_key_id @remote_actor <> "#main-key"
  @remote_inbox @remote_actor <> "/inbox"

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp federating_page do
    page =
      active_organization_for(insert(:activated_user))
      |> Ecto.Changeset.change(%{fediverse_followers?: true, username: "acme"})
      |> Repo.update!()

    {:ok, _} = Fediverse.ensure_organization_actor(page)
    page
  end

  defp host, do: VutuvWeb.Endpoint.host()

  defp stub_remote_actor(pub_pem) do
    doc =
      Jason.encode!(%{
        "id" => @remote_actor,
        "type" => "Person",
        "inbox" => @remote_inbox,
        "publicKey" => %{"id" => @remote_key_id, "publicKeyPem" => pub_pem}
      })

    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(200, doc)
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp signed_post(conn, page, activity, private_pem) do
    path = "/organizations/#{page.slug}/actor/inbox"
    body = Jason.encode!(activity)

    headers =
      HttpSignature.signed_headers(
        "post",
        "https://#{host()}#{path}",
        body,
        @remote_key_id,
        private_pem
      )

    conn = %{conn | host: host()}

    headers
    |> Enum.reject(fn {name, _} -> name == "host" end)
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> put_req_header("content-type", "application/activity+json")
    |> post(path, body)
  end

  defp follow_activity(page) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "https://social.example/follows/1",
      "type" => "Follow",
      "actor" => @remote_actor,
      "object" => Docs.actor_url(page)
    }
  end

  test "a signed Follow is recorded and answered with an Accept", %{conn: conn} do
    page = federating_page()
    {priv, pub} = Keys.generate()
    stub_remote_actor(pub)

    assert conn |> signed_post(page, follow_activity(page), priv) |> response(202)

    assert Fediverse.organization_remote_follower_count(page) == 1

    # The Accept is what stops Mastodon showing the follow as pending forever,
    # so its absence would be the actual failure, not a missing nicety.
    accept = Repo.one!(from(d in Delivery, where: d.organization_id == ^page.id))
    assert accept.inbox_uri == @remote_inbox
    assert accept.activity_json =~ ~s("type":"Accept")
    assert accept.activity_json =~ Docs.actor_url(page)
    assert is_nil(accept.user_id)
  end

  test "an Undo drops the follower again", %{conn: conn} do
    page = federating_page()
    {priv, pub} = Keys.generate()
    stub_remote_actor(pub)

    conn |> signed_post(page, follow_activity(page), priv) |> response(202)
    assert Fediverse.organization_remote_follower_count(page) == 1

    undo = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "https://social.example/undos/1",
      "type" => "Undo",
      "actor" => @remote_actor,
      "object" => %{"type" => "Follow", "object" => Docs.actor_url(page)}
    }

    assert build_conn() |> signed_post(page, undo, priv) |> response(202)
    assert Fediverse.organization_remote_follower_count(page) == 0
  end

  test "a Follow naming another actor is not a follow of this page", %{conn: conn} do
    page = federating_page()
    {priv, pub} = Keys.generate()
    stub_remote_actor(pub)

    elsewhere = %{follow_activity(page) | "object" => "https://social.example/users/bob"}

    # Acknowledged — the signature was valid — but it must not mint a follower.
    assert conn |> signed_post(page, elsewhere, priv) |> response(202)
    assert Fediverse.organization_remote_follower_count(page) == 0
  end

  test "an unsigned delivery is refused", %{conn: conn} do
    page = federating_page()

    assert conn
           |> put_req_header("content-type", "application/activity+json")
           |> post(
             "/organizations/#{page.slug}/actor/inbox",
             Jason.encode!(follow_activity(page))
           )
           |> response(401)

    assert Fediverse.organization_remote_follower_count(page) == 0
  end

  test "a page that has not opted in has no inbox", %{conn: conn} do
    page = active_organization_for(insert(:activated_user))
    {priv, pub} = Keys.generate()
    stub_remote_actor(pub)

    assert conn |> signed_post(page, follow_activity(page), priv) |> response(404)
  end
end
