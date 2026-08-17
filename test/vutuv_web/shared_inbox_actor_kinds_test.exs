defmodule VutuvWeb.SharedInboxActorKindsTest do
  @moduledoc """
  The shared inbox (`/system/inbox`) reaching a **page** and a **topic**, not
  only a member.

  Why this matters more than the per-actor inboxes it duplicates: every actor
  document we serve advertises `endpoints.sharedInbox` (it is a fact about the
  installation, not about the actor), and Mastodon — like most implementations —
  then prefers it over the actor's own inbox for everything it delivers. So a
  page's `/organizations/:slug/actor/inbox` is largely a spare door, and while
  the shared inbox resolved members only, every signed activity for a page
  resolved to nobody and was dropped with a 202: a `Follow` of the page, a
  favourite of its post, and — as reported — an **answer** to its post, which
  simply never appeared here.

  `async: false` because remote-actor fetching is stubbed through the application
  env and the organization helpers flip the DNS-verification flag.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.HttpSignature
  alias Vutuv.Fediverse.Keys
  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias VutuvWeb.Fediverse.Docs

  @remote_actor "https://social.example/users/alice"
  @remote_key_id @remote_actor <> "#main-key"
  @remote_inbox @remote_actor <> "/inbox"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp federating_page(username \\ "acme") do
    page =
      insert(:activated_user)
      |> active_organization_for()
      |> Ecto.Changeset.change(%{fediverse_followers?: true, username: username})
      |> Repo.update!()

    {:ok, _} = Fediverse.ensure_organization_actor(page)
    page
  end

  defp page_post(page, body) do
    owner = page |> Organizations.list_roles() |> hd() |> Map.fetch!(:user)
    {:ok, _} = Organizations.add_role(page, owner, "publisher", owner)
    {:ok, post} = Posts.create_organization_post(page, owner, %{body: body})
    post
  end

  defp host, do: VutuvWeb.Endpoint.host()

  defp stub_remote_actor(pub_pem) do
    doc =
      Jason.encode!(%{
        "id" => @remote_actor,
        "type" => "Person",
        "preferredUsername" => "alice",
        "name" => "Alice Remote",
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

  defp shared_post(conn, activity, private_pem) do
    path = "/system/inbox"
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

  describe "which of our actors an activity names" do
    test "a page, by its actor URL and by one of its post URLs" do
      page = federating_page()
      post = page_post(page, "Hallo.")

      for uri <- [Docs.actor_url(page), Docs.note_url(page, post.id)] do
        activity = %{"type" => "Create", "to" => [uri], "object" => %{}}
        assert [%Organizations.Organization{id: found}] = recipients(activity)
        assert found == page.id
      end
    end

    test "a topic, whose actor lives on the tag host" do
      tag = insert(:tag)
      {:ok, _} = Fediverse.ensure_tag_actor(tag)

      activity = %{"type" => "Follow", "object" => Docs.actor_url(tag)}

      assert [%Vutuv.Tags.Tag{id: found}] = recipients(activity)
      assert found == tag.id
    end

    test "a page the `www.` alias names is still the page" do
      page = federating_page()

      www =
        page
        |> Docs.actor_url()
        |> URI.parse()
        |> then(&%{&1 | host: "www." <> &1.host})
        |> URI.to_string()

      assert [%Organizations.Organization{}] = recipients(%{"type" => "Follow", "object" => www})
    end

    test "a page that has not switched federation on is nobody" do
      page = insert(:activated_user) |> active_organization_for()

      assert recipients(%{"type" => "Follow", "object" => Docs.actor_url(page)}) == []
    end

    defp recipients(activity), do: Fediverse.inbox_recipients(activity, @remote_actor)
  end

  test "an answer to a page's post arrives through the shared inbox", %{conn: conn} do
    page = federating_page()
    post = page_post(page, "Wir stellen ein.")
    {priv, pub} = Keys.generate()
    stub_remote_actor(pub)

    activity = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "https://social.example/notes/1/activity",
      "type" => "Create",
      "actor" => @remote_actor,
      "to" => [@public],
      "cc" => [Docs.actor_url(page)],
      "object" => %{
        "id" => "https://social.example/notes/1",
        "type" => "Note",
        "attributedTo" => @remote_actor,
        "to" => [@public],
        "inReplyTo" => Docs.note_url(page, post.id),
        "content" => "<p>Ich bewerbe mich.</p>"
      }
    }

    assert conn |> shared_post(activity, priv) |> response(202)

    # The reported bug: the delivery was acknowledged and thrown away, so the
    # answer existed on the other server and nowhere here.
    assert [note] = Fediverse.list_notes([post.id], nil)[post.id]
    assert note.content_text =~ "Ich bewerbe mich."
  end

  test "a Follow of a page arrives through the shared inbox too", %{conn: conn} do
    page = federating_page("beta")
    {priv, pub} = Keys.generate()
    stub_remote_actor(pub)

    activity = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "https://social.example/follows/1",
      "type" => "Follow",
      "actor" => @remote_actor,
      "object" => Docs.actor_url(page)
    }

    assert conn |> shared_post(activity, priv) |> response(202)
    assert Fediverse.organization_remote_follower_count(page) == 1
  end
end
