defmodule VutuvWeb.MastodonApi.SocialControllerTest do
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers
  import Vutuv.OrganizationsHelpers

  alias Vutuv.MastodonApi.Access
  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Social

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

  test "a personal identity reads its home timeline and posts", %{conn: conn} do
    reader = insert(:activated_user)
    author = insert(:activated_user)
    {:ok, _follow} = Social.follow(reader, author.id)
    {:ok, post} = Posts.create_post(author, %{body: "From the feed"})
    token = mastodon_token(reader, ["read", "write"])

    [status] = conn |> mastodon_conn(token) |> get("/api/v1/timelines/home") |> json_response(200)
    assert status["id"] == post.id

    created =
      build_conn()
      |> mastodon_conn(token)
      |> post("/api/v1/statuses", %{"status" => "From the phone"})
      |> json_response(200)

    assert Posts.get_post(created["id"]).user_id == reader.id
  end

  test "search resolves local addresses and organization slugs", %{conn: conn} do
    user = insert(:activated_user)
    organization = active_organization_for(insert(:activated_user))
    token = mastodon_token(user, ["read"])

    local_address = URI.encode_www_form("@#{user.username}@localhost")

    %{"accounts" => [found_user]} =
      conn
      |> mastodon_conn(token)
      |> get("/api/v2/search?q=#{local_address}")
      |> json_response(200)

    assert found_user["id"] == user.id

    %{"accounts" => [found_organization]} =
      build_conn()
      |> mastodon_conn(token)
      |> get("/api/v2/search?q=#{organization.slug}")
      |> json_response(200)

    assert found_organization["id"] == organization.id
  end

  # The one endpoint here that takes a list of ids and does per-id work: a
  # lookup, a visibility check and a handful of relationship queries each. Left
  # unbounded, one request with a few hundred ids is a thousand queries
  # somebody else's phone waits behind — and a repeated id is pointless to
  # answer twice.
  test "the relationships list is deduplicated and capped", %{conn: conn} do
    reader = insert(:activated_user)
    subject = insert(:activated_user)
    token = mastodon_token(reader, ["read"])

    repeated = Enum.map_join(1..10, "&", fn _n -> "id[]=#{subject.id}" end)

    assert [_one] =
             conn
             |> mastodon_conn(token)
             |> get("/api/v1/accounts/relationships?#{repeated}")
             |> json_response(200)

    many = Enum.map_join(1..45, "&", fn _n -> "id[]=#{insert(:activated_user).id}" end)

    answered =
      build_conn()
      |> mastodon_conn(token)
      |> get("/api/v1/accounts/relationships?#{many}")
      |> json_response(200)

    assert length(answered) == 40
  end

  # `www.` is us. A member pastes whatever their browser or a share button handed
  # them, and the apex and its `www.` alias are the same site — but the resolver
  # compared the host against a two-entry list, so this address fell through to
  # the *remote* branch and the installation WebFingered itself over the network
  # instead of answering from its own tables.
  test "search resolves an address on the www. alias as one of ours", %{conn: conn} do
    user = insert(:activated_user)
    token = mastodon_token(user, ["read"])

    address = URI.encode_www_form("@#{user.username}@www.localhost")

    %{"accounts" => [found]} =
      conn
      |> mastodon_conn(token)
      |> get("/api/v2/search?q=#{address}")
      |> json_response(200)

    assert found["id"] == user.id
  end

  test "a personal identity edits, replies to and engages with statuses", %{conn: conn} do
    user = insert(:activated_user)
    author = insert(:activated_user)
    {:ok, parent} = Posts.create_post(author, %{body: "A public post"})
    token = mastodon_token(user, ["read", "write"])

    reply =
      conn
      |> mastodon_conn(token)
      |> post("/api/v1/statuses", %{
        "status" => "A phone reply",
        "in_reply_to_id" => parent.id
      })
      |> json_response(200)

    edited =
      build_conn()
      |> mastodon_conn(token)
      |> put("/api/v1/statuses/#{reply["id"]}", %{"status" => "An edited phone reply"})
      |> json_response(200)

    assert edited["content"] =~ "An edited phone reply"
    assert edited["in_reply_to_id"] == parent.id

    assert build_conn()
           |> mastodon_conn(token)
           |> post("/api/v1/statuses/#{parent.id}/favourite")
           |> json_response(200)
           |> Map.fetch!("favourited")

    assert build_conn()
           |> mastodon_conn(token)
           |> post("/api/v1/statuses/#{parent.id}/bookmark")
           |> json_response(200)
           |> Map.fetch!("bookmarked")

    assert build_conn()
           |> mastodon_conn(token)
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
    token = mastodon_token(member, ["read", "write", "follow"], organization)

    [status] = conn |> mastodon_conn(token) |> get("/api/v1/timelines/home") |> json_response(200)
    assert status["id"] == post.id

    created =
      build_conn()
      |> mastodon_conn(token)
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

    personal_token = mastodon_token(member, ["read"])
    organization_token = mastodon_token(member, ["read", "write"], organization)

    personal_statuses =
      conn
      |> mastodon_conn(personal_token)
      |> get("/api/v1/accounts/#{author.id}/statuses")
      |> json_response(200)

    assert Enum.any?(personal_statuses, &(&1["id"] == private_post.id))

    organization_statuses =
      build_conn()
      |> mastodon_conn(organization_token)
      |> get("/api/v1/accounts/#{author.id}/statuses")
      |> json_response(200)

    refute Enum.any?(organization_statuses, &(&1["id"] == private_post.id))

    assert build_conn()
           |> mastodon_conn(organization_token)
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
    token = mastodon_token(member, ["read", "write", "follow"], organization)

    assert conn
           |> mastodon_conn(token)
           |> post("/api/v1/statuses", %{"status" => "Allowed"})
           |> response(200)

    assert build_conn()
           |> mastodon_conn(token)
           |> post("/api/v1/accounts/#{target.id}/follow")
           |> response(200)

    {:ok, _} = Organizations.set_roles(organization, member, ["owner"], member)

    assert build_conn()
           |> mastodon_conn(token)
           |> post("/api/v1/statuses", %{"status" => "No longer allowed"})
           |> response(403)

    assert build_conn()
           |> mastodon_conn(token)
           |> post("/api/v1/accounts/#{target.id}/unfollow")
           |> response(403)
  end

  # Owning or administering a page is not speaking for it (#1333), and the
  # adapter adds no role of its own — so a member who holds every
  # administrative role but not `publisher` is offered no organization
  # identity at all and cannot mint a token for one.
  test "an administrative role alone offers no organization identity" do
    member = allow_mastodon_clients(insert(:activated_user))
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
    token = mastodon_token(member, ["read", "follow"], organization)

    relationship =
      conn
      |> mastodon_conn(token)
      |> post("/api/v1/accounts/#{target.id}/follow")
      |> json_response(200)

    assert relationship["following"]

    muted =
      build_conn()
      |> mastodon_conn(token)
      |> post("/api/v1/accounts/#{target.id}/mute")
      |> json_response(200)

    assert muted["muting"]

    following =
      build_conn()
      |> mastodon_conn(token)
      |> get("/api/v1/accounts/#{organization.id}/following")
      |> json_response(200)

    assert Enum.any?(following, &(&1["id"] == target.id))

    verified =
      build_conn()
      |> mastodon_conn(token)
      |> get("/api/v1/accounts/verify_credentials")
      |> json_response(200)

    assert verified["following_count"] == 1

    personal_token = mastodon_token(member, ["read"])

    assert build_conn()
           |> mastodon_conn(personal_token)
           |> get("/api/v1/accounts/#{organization.id}/following")
           |> json_response(200) == []

    assert build_conn()
           |> mastodon_conn(token)
           |> post("/api/v1/accounts/#{target.id}/block")
           |> response(403)
  end

  test "a personal identity can block another local member", %{conn: conn} do
    user = insert(:activated_user)
    target = insert(:activated_user)
    token = mastodon_token(user, ["read", "follow"])

    conn
    |> mastodon_conn(token)
    |> post("/api/v1/accounts/#{target.id}/follow")
    |> json_response(200)

    muted =
      build_conn()
      |> mastodon_conn(token)
      |> post("/api/v1/accounts/#{target.id}/mute")
      |> json_response(200)

    assert muted["muting"]

    relationship =
      build_conn()
      |> mastodon_conn(token)
      |> post("/api/v1/accounts/#{target.id}/block")
      |> json_response(200)

    assert relationship["blocking"]
  end

  test "an identity opt-out stops an already issued token immediately", %{conn: conn} do
    user = insert(:activated_user)
    token = mastodon_token(user, ["read"])

    assert conn
           |> mastodon_conn(token)
           |> get("/api/v1/accounts/verify_credentials")
           |> response(200)

    refute deny_mastodon_clients(user).mastodon_clients?

    assert build_conn()
           |> mastodon_conn(token)
           |> get("/api/v1/accounts/verify_credentials")
           |> response(403)
  end

  test "an organization opt-out stops an already issued token immediately", %{conn: conn} do
    member = insert(:activated_user)
    organization = active_organization_for(member)
    {:ok, _} = Organizations.add_role(organization, member, "publisher", member)
    token = mastodon_token(member, ["read"], organization)

    assert conn
           |> mastodon_conn(token)
           |> get("/api/v1/accounts/verify_credentials")
           |> response(200)

    refute deny_mastodon_clients(organization).mastodon_clients?

    assert build_conn()
           |> mastodon_conn(token)
           |> get("/api/v1/accounts/verify_credentials")
           |> response(403)
  end
end
