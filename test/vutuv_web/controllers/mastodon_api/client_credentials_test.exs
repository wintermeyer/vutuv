defmodule VutuvWeb.MastodonApi.ClientCredentialsTest do
  @moduledoc """
  `grant_type=client_credentials` — a token for the app, with no member behind
  it (RFC 6749 §4.4), which Mastodon's token endpoint answers.

  This exists because of a real phone: Ivory, pointed at `vutuv.de`, churned for
  a few seconds and gave up with `unsupported_grant_type` **before** any consent
  screen appeared. A client asks for an app token right after registering itself,
  and refusing it ends setup there — everything downstream of it, the whole
  two-host arrangement included, was already working.

  The tests below are in two halves and the second is the important one. The
  first says the grant works — remove the controller clause and eleven of these
  fourteen go red, the three survivors being the two that assert a refusal the
  fall-through already gives and the one that reads the discovery document. The
  second half says the credential cannot reach a member's data.

  That second half is **not** calibrated against un-fixed code, and saying so
  matters: there is no fix to revert, because the separation is structural. An
  app token lives in `oauth_app_tokens`, every member-scoped endpoint
  authenticates through `api_tokens`, and neither table can answer for the other
  — so these tests pin a property down rather than guard a patch, and an endpoint
  added to the member pipeline later inherits it without knowing this file
  exists. Had the token instead been a row in `api_tokens` with a null
  `user_id`, each of these paths would have needed its own explicit refusal, and
  the inner join in `ApiAuth.lookup/1` would have swallowed the row in silence.

  `async: false` because the endpoints here are rate limited per client.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.App
  alias Vutuv.ApiAuth.AppToken
  alias Vutuv.ApiAuth.OAuth
  alias Vutuv.Repo
  alias VutuvWeb.MastodonApi.StreamingSocket

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  # A Mastodon client registers itself through the public endpoint, exactly as a
  # phone does, so the app under test is the shape that flow really produces
  # (`user_id` nil, `protocol` "mastodon") rather than one built by hand.
  defp register_client(conn, scopes \\ "read write") do
    conn
    |> on_mastodon_host()
    |> post("/api/v1/apps", %{
      "client_name" => "Pocket Client",
      "redirect_uris" => ["org.example.client://oauth"],
      "scopes" => scopes
    })
    |> json_response(200)
  end

  defp app_token(conn, credentials) do
    conn
    |> on_mastodon_host()
    |> post("/oauth/token", %{
      "grant_type" => "client_credentials",
      "client_id" => credentials["client_id"],
      "client_secret" => credentials["client_secret"]
    })
  end

  describe "the grant" do
    test "answers a bearer token carrying the app's registered scopes", %{conn: conn} do
      credentials = register_client(conn, "read write:statuses")

      body = build_conn() |> app_token(credentials) |> json_response(200)

      assert body["token_type"] == "Bearer"
      assert body["scope"] == "read write:statuses"
      assert is_integer(body["created_at"])
      assert String.starts_with?(body["access_token"], "vutuv_at_")

      # Only the hash is stored, like every other credential here.
      token = Repo.get_by!(AppToken, token_hash: ApiAuth.hash_token(body["access_token"]))
      assert token.scopes == ["read", "write:statuses"]
      refute token.token_hash == body["access_token"]
    end

    # RFC 6749 §5.1: a token response must not be cached anywhere.
    test "is not cacheable", %{conn: conn} do
      credentials = register_client(conn)
      response = build_conn() |> app_token(credentials)

      assert get_resp_header(response, "cache-control") == ["no-store"]
    end

    test "refuses a wrong or missing client secret", %{conn: conn} do
      credentials = register_client(conn)

      assert %{"error" => "invalid_client"} =
               build_conn()
               |> app_token(%{credentials | "client_secret" => "vutuv_sec_wrong"})
               |> json_response(401)

      assert %{"error" => "invalid_client"} =
               build_conn()
               |> on_mastodon_host()
               |> post("/oauth/token", %{
                 "grant_type" => "client_credentials",
                 "client_id" => credentials["client_id"]
               })
               |> json_response(401)
    end

    test "refuses a suspended app", %{conn: conn} do
      credentials = register_client(conn)

      Repo.get_by!(App, client_id: credentials["client_id"])
      |> Ecto.Changeset.change(suspended_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert %{"error" => "invalid_client"} =
               build_conn() |> app_token(credentials) |> json_response(401)
    end

    # A native vutuv OAuth app is a user-facing thing with mandatory PKCE, and
    # nothing in that flow wants an app-level credential. Answering the grant
    # there would widen /api/2.0's surface for nobody.
    test "is not offered to a native vutuv app", %{conn: conn} do
      developer = insert_activated_user()

      {:ok, app, secret} =
        ApiAuth.create_app(developer, %{
          "name" => "Native App",
          "redirect_uris" => ["https://native.example.org/oauth"]
        })

      assert %{"error" => "unsupported_grant_type"} =
               conn
               |> on_mastodon_host()
               |> post("/oauth/token", %{
                 "grant_type" => "client_credentials",
                 "client_id" => app.client_id,
                 "client_secret" => secret
               })
               |> json_response(400)
    end

    # The address a member types is the main host, which is the whole reason the
    # adapter answers on both.
    test "works on the main host too", %{conn: conn} do
      credentials = register_client(conn)

      body =
        build_conn()
        |> Map.put(:host, "localhost")
        |> post("/oauth/token", %{
          "grant_type" => "client_credentials",
          "client_id" => credentials["client_id"],
          "client_secret" => credentials["client_secret"]
        })
        |> json_response(200)

      assert String.starts_with?(body["access_token"], "vutuv_at_")
    end

    test "is advertised in the discovery document", %{conn: conn} do
      metadata =
        conn
        |> on_mastodon_host()
        |> get("/.well-known/oauth-authorization-server")
        |> json_response(200)

      assert "client_credentials" in metadata["grant_types_supported"]
      assert "authorization_code" in metadata["grant_types_supported"]
    end
  end

  describe "the app token" do
    setup %{conn: conn} do
      credentials = register_client(conn)
      body = build_conn() |> app_token(credentials) |> json_response(200)
      {:ok, credentials: credentials, token: body["access_token"]}
    end

    test "identifies the app, without echoing its credentials back", %{token: token} do
      body =
        build_conn()
        |> on_mastodon_host()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/api/v1/apps/verify_credentials")
        |> json_response(200)

      assert body["name"] == "Pocket Client"
      assert body["scopes"] == ["read", "write"]
      # The client already holds both; echoing one back to whoever presents a
      # token is how a credential reaches a log.
      refute Map.has_key?(body, "client_id")
      refute Map.has_key?(body, "client_secret")
    end

    test "stamps when it was last used", %{token: token} do
      stored = Repo.get_by!(AppToken, token_hash: ApiAuth.hash_token(token))
      assert is_nil(stored.last_used_at)

      build_conn()
      |> on_mastodon_host()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/v1/apps/verify_credentials")
      |> json_response(200)

      assert Repo.reload!(stored).last_used_at
    end

    test "stops working once revoked or once its app is suspended", %{
      token: token,
      credentials: credentials
    } do
      stored = Repo.get_by!(AppToken, token_hash: ApiAuth.hash_token(token))
      stored |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second)) |> Repo.update!()

      assert is_nil(OAuth.verify_app_token(token))

      # A fresh token, then the app itself goes: the credential must not outlive
      # the thing it identifies.
      live = build_conn() |> app_token(credentials) |> json_response(200)
      assert OAuth.verify_app_token(live["access_token"])

      Repo.get_by!(App, client_id: credentials["client_id"])
      |> Ecto.Changeset.change(suspended_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert is_nil(OAuth.verify_app_token(live["access_token"]))
    end

    test "an unknown or empty bearer is refused", %{conn: conn} do
      for header <- ["Bearer vutuv_at_nope", "Bearer ", "Basic whatever"] do
        assert build_conn()
               |> on_mastodon_host()
               |> put_req_header("authorization", header)
               |> get("/api/v1/apps/verify_credentials")
               |> json_response(401)
      end

      assert conn
             |> on_mastodon_host()
             |> get("/api/v1/apps/verify_credentials")
             |> json_response(401)
    end
  end

  # The point of the separate table, stated as a test. Calibrated against the
  # alternative that was considered and rejected: were an app token a row in
  # `api_tokens` with a null `user_id`, each of these would have to be refused by
  # a check somewhere, and the inner join in `ApiAuth.lookup/1` would have
  # swallowed the row in silence instead.
  describe "an app token cannot reach a member's data" do
    setup %{conn: conn} do
      credentials = register_client(conn)
      body = build_conn() |> app_token(credentials) |> json_response(200)
      {:ok, token: body["access_token"]}
    end

    test "not on a read, not on a write, not on a timeline", %{token: token} do
      target = insert(:activated_user)

      for {method, path} <- [
            {:get, "/api/v1/accounts/verify_credentials"},
            {:get, "/api/v1/timelines/home"},
            {:get, "/api/v1/notifications"},
            {:get, "/api/v1/bookmarks"},
            {:post, "/api/v1/statuses"},
            {:post, "/api/v1/accounts/#{target.id}/follow"}
          ] do
        conn =
          build_conn()
          |> on_mastodon_host()
          |> put_req_header("authorization", "Bearer " <> token)

        response =
          case method do
            :get -> get(conn, path)
            :post -> post(conn, path, %{"status" => "Hallo"})
          end

        assert response.status in [401, 403],
               "#{method} #{path} answered #{response.status} to an app token"
      end
    end

    test "and it cannot open the streaming socket", %{token: token} do
      transport = %{
        params: %{"access_token" => token},
        connect_info: %{uri: URI.parse("ws://mastodon.localhost/api/v1/streaming"), x_headers: []}
      }

      assert StreamingSocket.connect(transport) == :error
    end

    # The mirror image: a member's own bearer token is not an app credential
    # either, so the two cannot be swapped in either direction.
    test "and a member token cannot identify an app" do
      member_token = mastodon_token(insert(:activated_user), ["read"])

      assert is_nil(OAuth.verify_app_token(member_token))

      assert build_conn()
             |> on_mastodon_host()
             |> put_req_header("authorization", "Bearer " <> member_token)
             |> get("/api/v1/apps/verify_credentials")
             |> json_response(401)
    end
  end
end
