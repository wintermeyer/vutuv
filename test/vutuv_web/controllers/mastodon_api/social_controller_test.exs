defmodule VutuvWeb.MastodonApi.SocialControllerTest do
  use VutuvWeb.ConnCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.ApiAuth
  alias Vutuv.MastodonApi.Access
  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Social

  @mastodon_host "mastodon.localhost"

  setup do
    original_verification = Application.fetch_env(:vutuv, :verify_organization_domains)
    original_resolver = Application.fetch_env(:vutuv, :organizations_dns_resolver)
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      case original_verification do
        {:ok, value} -> Application.put_env(:vutuv, :verify_organization_domains, value)
        :error -> Application.delete_env(:vutuv, :verify_organization_domains)
      end

      case original_resolver do
        {:ok, value} -> Application.put_env(:vutuv, :organizations_dns_resolver, value)
        :error -> Application.delete_env(:vutuv, :organizations_dns_resolver)
      end
    end)

    :ok
  end

  defp token_for(user, scopes, organization \\ nil) do
    plaintext = "vutuv_at_" <> ApiAuth.random_token()

    app =
      insert(:oauth_app,
        user: nil,
        protocol: "mastodon",
        registered_scopes: scopes
      )

    insert(:api_token,
      user: user,
      app: app,
      organization: organization,
      kind: "access",
      name: nil,
      scopes: scopes,
      expires_at: nil,
      token_hash: ApiAuth.hash_token(plaintext)
    )

    plaintext
  end

  defp api(conn, token) do
    conn
    |> Map.put(:host, @mastodon_host)
    |> put_req_header("authorization", "Bearer " <> token)
  end

  test "a personal identity reads its home timeline and posts", %{conn: conn} do
    reader = insert(:activated_user)
    author = insert(:activated_user)
    {:ok, _follow} = Social.follow(reader, author.id)
    {:ok, post} = Posts.create_post(author, %{body: "From the feed"})
    token = token_for(reader, ["read", "write"])

    [status] = conn |> api(token) |> get("/api/v1/timelines/home") |> json_response(200)
    assert status["id"] == post.id

    created =
      build_conn()
      |> api(token)
      |> post("/api/v1/statuses", %{"status" => "From the phone"})
      |> json_response(200)

    assert Posts.get_post(created["id"]).user_id == reader.id
  end

  test "search resolves local addresses and organization slugs", %{conn: conn} do
    user = insert(:activated_user)
    organization = active_organization_for(insert(:activated_user))
    token = token_for(user, ["read"])

    local_address = URI.encode_www_form("@#{user.username}@localhost")

    %{"accounts" => [found_user]} =
      conn
      |> api(token)
      |> get("/api/v2/search?q=#{local_address}")
      |> json_response(200)

    assert found_user["id"] == user.id

    %{"accounts" => [found_organization]} =
      build_conn()
      |> api(token)
      |> get("/api/v2/search?q=#{organization.slug}")
      |> json_response(200)

    assert found_organization["id"] == organization.id
  end

  test "a personal identity edits, replies to and engages with statuses", %{conn: conn} do
    user = insert(:activated_user)
    author = insert(:activated_user)
    {:ok, parent} = Posts.create_post(author, %{body: "A public post"})
    token = token_for(user, ["read", "write"])

    reply =
      conn
      |> api(token)
      |> post("/api/v1/statuses", %{
        "status" => "A phone reply",
        "in_reply_to_id" => parent.id
      })
      |> json_response(200)

    edited =
      build_conn()
      |> api(token)
      |> put("/api/v1/statuses/#{reply["id"]}", %{"status" => "An edited phone reply"})
      |> json_response(200)

    assert edited["content"] =~ "An edited phone reply"
    assert edited["in_reply_to_id"] == parent.id

    assert build_conn()
           |> api(token)
           |> post("/api/v1/statuses/#{parent.id}/favourite")
           |> json_response(200)
           |> Map.fetch!("favourited")

    assert build_conn()
           |> api(token)
           |> post("/api/v1/statuses/#{parent.id}/bookmark")
           |> json_response(200)
           |> Map.fetch!("bookmarked")

    assert build_conn()
           |> api(token)
           |> post("/api/v1/statuses/#{parent.id}/reblog")
           |> json_response(200)
           |> Map.fetch!("reblogged")
  end

  test "an organization identity uses its own feed and publishes in its own name", %{conn: conn} do
    member = insert(:activated_user)
    organization = active_organization_for(member)
    {:ok, _} = Organizations.add_role(organization, member, "publisher", member)

    author = insert(:activated_user)
    {:ok, _follow} = Social.follow_as_organization(organization, author)
    {:ok, post} = Posts.create_post(author, %{body: "For the organization"})
    token = token_for(member, ["read", "write", "follow"], organization)

    [status] = conn |> api(token) |> get("/api/v1/timelines/home") |> json_response(200)
    assert status["id"] == post.id

    created =
      build_conn()
      |> api(token)
      |> post("/api/v1/statuses", %{"status" => "Organization announcement"})
      |> json_response(200)

    stored = Posts.get_post(created["id"])
    assert stored.organization_id == organization.id
    assert stored.acting_user_id == member.id
  end

  test "an organization identity does not inherit the member's private profile view", %{
    conn: conn
  } do
    member = insert(:activated_user)
    author = insert(:activated_user)
    organization = active_organization_for(member)
    {:ok, _} = Organizations.add_role(organization, member, "publisher", member)
    {:ok, _} = Social.follow(member, author.id)

    {:ok, private_post} =
      Posts.create_post(author, %{
        body: "Followers only",
        denials: [%{wildcard: "non_followers"}]
      })

    personal_token = token_for(member, ["read"])
    organization_token = token_for(member, ["read", "write"], organization)

    personal_statuses =
      conn
      |> api(personal_token)
      |> get("/api/v1/accounts/#{author.id}/statuses")
      |> json_response(200)

    assert Enum.any?(personal_statuses, &(&1["id"] == private_post.id))

    organization_statuses =
      build_conn()
      |> api(organization_token)
      |> get("/api/v1/accounts/#{author.id}/statuses")
      |> json_response(200)

    refute Enum.any?(organization_statuses, &(&1["id"] == private_post.id))

    assert build_conn()
           |> api(organization_token)
           |> post("/api/v1/statuses/#{private_post.id}/favourite")
           |> response(404)
  end

  # Withdrawing the role narrows a token that has already been issued, rather
  # than waiting for it to expire — which matters more here than anywhere else,
  # because a Mastodon access token carries no expiry at all.
  test "withdrawing the editorial role stops an already issued token", %{conn: conn} do
    member = insert(:activated_user)
    target = insert(:activated_user)
    organization = active_organization_for(member)
    {:ok, _} = Organizations.add_role(organization, member, "publisher", member)
    token = token_for(member, ["read", "write", "follow"], organization)

    assert conn
           |> api(token)
           |> post("/api/v1/statuses", %{"status" => "Allowed"})
           |> response(200)

    assert build_conn()
           |> api(token)
           |> post("/api/v1/accounts/#{target.id}/follow")
           |> response(200)

    {:ok, _} = Organizations.set_roles(organization, member, ["owner"], member)

    assert build_conn()
           |> api(token)
           |> post("/api/v1/statuses", %{"status" => "No longer allowed"})
           |> response(403)

    assert build_conn()
           |> api(token)
           |> post("/api/v1/accounts/#{target.id}/unfollow")
           |> response(403)
  end

  # Owning or administering a page is not speaking for it (#1333), and the
  # adapter adds no role of its own — so a member who holds every
  # administrative role but not `publisher` is offered no organization
  # identity at all and cannot mint a token for one.
  test "an administrative role alone offers no organization identity" do
    member = insert(:activated_user)
    organization = active_organization_for(member)
    {:ok, _} = Organizations.add_role(organization, member, "admin", member)

    assert Access.identities(member, ["read", "write"]) == [
             %{value: "person", subject: member, scopes: ["read", "write"]}
           ]

    assert Access.select(member, "organization:" <> organization.id, ["read"]) ==
             {:error, :forbidden}
  end

  test "a publisher follows and mutes but has no organization block scope", %{conn: conn} do
    member = insert(:activated_user)
    target = insert(:activated_user)
    organization = active_organization_for(member)
    {:ok, _} = Organizations.add_role(organization, member, "publisher", member)
    token = token_for(member, ["read", "follow"], organization)

    relationship =
      conn
      |> api(token)
      |> post("/api/v1/accounts/#{target.id}/follow")
      |> json_response(200)

    assert relationship["following"]

    muted =
      build_conn()
      |> api(token)
      |> post("/api/v1/accounts/#{target.id}/mute")
      |> json_response(200)

    assert muted["muting"]

    following =
      build_conn()
      |> api(token)
      |> get("/api/v1/accounts/#{organization.id}/following")
      |> json_response(200)

    assert Enum.any?(following, &(&1["id"] == target.id))

    verified =
      build_conn()
      |> api(token)
      |> get("/api/v1/accounts/verify_credentials")
      |> json_response(200)

    assert verified["following_count"] == 1

    personal_token = token_for(member, ["read"])

    assert build_conn()
           |> api(personal_token)
           |> get("/api/v1/accounts/#{organization.id}/following")
           |> json_response(200) == []

    assert build_conn()
           |> api(token)
           |> post("/api/v1/accounts/#{target.id}/block")
           |> response(403)
  end

  test "a personal identity can block another local member", %{conn: conn} do
    user = insert(:activated_user)
    target = insert(:activated_user)
    token = token_for(user, ["read", "follow"])

    conn
    |> api(token)
    |> post("/api/v1/accounts/#{target.id}/follow")
    |> json_response(200)

    muted =
      build_conn()
      |> api(token)
      |> post("/api/v1/accounts/#{target.id}/mute")
      |> json_response(200)

    assert muted["muting"]

    relationship =
      build_conn()
      |> api(token)
      |> post("/api/v1/accounts/#{target.id}/block")
      |> json_response(200)

    assert relationship["blocking"]
  end

  test "an identity opt-out stops an already issued token immediately", %{conn: conn} do
    user = insert(:activated_user)
    token = token_for(user, ["read"])

    assert conn |> api(token) |> get("/api/v1/accounts/verify_credentials") |> response(200)

    {:ok, user} = user |> Ecto.Changeset.change(mastodon_clients?: false) |> Vutuv.Repo.update()
    refute user.mastodon_clients?

    assert build_conn()
           |> api(token)
           |> get("/api/v1/accounts/verify_credentials")
           |> response(403)
  end

  test "an organization opt-out stops an already issued token immediately", %{conn: conn} do
    member = insert(:activated_user)
    organization = active_organization_for(member)
    {:ok, _} = Organizations.add_role(organization, member, "publisher", member)
    token = token_for(member, ["read"], organization)

    assert conn |> api(token) |> get("/api/v1/accounts/verify_credentials") |> response(200)

    {:ok, organization} = Organizations.set_mastodon_clients(organization, false)
    refute organization.mastodon_clients?

    assert build_conn()
           |> api(token)
           |> get("/api/v1/accounts/verify_credentials")
           |> response(403)
  end
end
