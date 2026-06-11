defmodule VutuvWeb.ApiV1Test do
  use VutuvWeb.ConnCase

  alias Vutuv.ApiAuth

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()
    user = insert_activated_user()

    {:ok, plaintext, token} =
      ApiAuth.create_pat(user, %{"name" => "Test", "scopes" => ["profile:read"]})

    {:ok, conn: conn, user: user, plaintext: plaintext, token: token}
  end

  defp authed(conn, plaintext) do
    put_req_header(conn, "authorization", "Bearer " <> plaintext)
  end

  defp problem(conn) do
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/problem+json"
    Jason.decode!(conn.resp_body)
  end

  describe "authentication" do
    test "no token is a 401 problem with WWW-Authenticate", %{conn: conn} do
      conn = get(conn, "/api/v1/me")
      assert conn.status == 401
      assert %{"title" => "Unauthorized", "status" => 401} = problem(conn)
      assert [www] = get_resp_header(conn, "www-authenticate")
      assert www =~ "Bearer"
    end

    test "an invalid token is a 401", %{conn: conn} do
      conn = conn |> authed("vutuv_pat_bogus") |> get("/api/v1/me")
      assert conn.status == 401
    end

    test "a revoked token is a 401 on the very next request", %{
      conn: conn,
      plaintext: plaintext,
      token: token
    } do
      assert authed(conn, plaintext) |> get("/api/v1/me") |> Map.fetch!(:status) == 200

      ApiAuth.revoke_token!(token)

      conn = build_conn() |> authed(plaintext) |> get("/api/v1/me")
      assert conn.status == 401
      assert problem(conn)["detail"] =~ "revoked"
    end

    test "unknown API paths are a JSON 404, not an HTML page", %{
      conn: conn,
      plaintext: plaintext
    } do
      conn = conn |> authed(plaintext) |> get("/api/v1/nonexistent")
      assert conn.status == 404
      assert %{"status" => 404} = problem(conn)
    end
  end

  describe "scopes" do
    test "a token without the needed scope gets a 403 naming it", %{conn: conn, user: user} do
      {:ok, plaintext, _} = ApiAuth.create_pat(user, %{"name" => "n", "scopes" => ["posts:read"]})

      conn = conn |> authed(plaintext) |> get("/api/v1/me")
      assert conn.status == 403
      assert problem(conn)["required_scope"] == "profile:read"
    end

    test "profile:write implies profile:read", %{conn: conn, user: user} do
      {:ok, plaintext, _} =
        ApiAuth.create_pat(user, %{"name" => "n", "scopes" => ["profile:write"]})

      conn = conn |> authed(plaintext) |> get("/api/v1/me")
      assert conn.status == 200
    end
  end

  describe "GET /api/v1/me" do
    test "returns the caller's profile through their own eyes", %{
      conn: conn,
      user: user,
      plaintext: plaintext
    } do
      insert(:email, user: user, public?: false, value: "private@example.com")

      conn = conn |> authed(plaintext) |> get("/api/v1/me")
      body = json_response(conn, 200)

      assert body["slug"] == user.active_slug
      assert "private@example.com" in body["emails"]
    end
  end

  describe "GET /api/v1/users/:slug" do
    test "returns another member's anonymous-public view", %{conn: conn, plaintext: plaintext} do
      other = insert_activated_user()
      insert(:email, user: other, public?: false, value: "private@example.com")
      insert(:email, user: other, public?: true, value: "public@example.com")

      conn = conn |> authed(plaintext) |> get("/api/v1/users/#{other.active_slug}")
      body = json_response(conn, 200)

      assert body["slug"] == other.active_slug
      assert "public@example.com" in body["emails"]
      refute "private@example.com" in body["emails"]
    end

    test "unactivated and moderation-hidden accounts 404 for strangers", %{
      conn: conn,
      plaintext: plaintext
    } do
      unactivated = insert(:user, activated?: false)

      conn1 = conn |> authed(plaintext) |> get("/api/v1/users/#{unactivated.active_slug}")
      assert conn1.status == 404

      frozen = insert_activated_user(frozen_at: NaiveDateTime.utc_now(:second))
      conn2 = build_conn() |> authed(plaintext) |> get("/api/v1/users/#{frozen.active_slug}")
      assert conn2.status == 404
    end

    test "a frozen profile stays visible to its owner, like the HTML page", %{conn: conn} do
      owner = insert_activated_user(frozen_at: NaiveDateTime.utc_now(:second))

      {:ok, plaintext, _} =
        ApiAuth.create_pat(owner, %{"name" => "n", "scopes" => ["profile:read"]})

      conn = conn |> authed(plaintext) |> get("/api/v1/users/#{owner.active_slug}")
      assert conn.status == 200
    end
  end

  describe "rate limiting" do
    test "per-token limit with headers, then 429", %{conn: conn, plaintext: plaintext} do
      Application.put_env(:vutuv, :api_v1_rate_limit, {2, 60_000})
      on_exit(fn -> Application.delete_env(:vutuv, :api_v1_rate_limit) end)

      conn1 = conn |> authed(plaintext) |> get("/api/v1/me")
      assert conn1.status == 200
      assert get_resp_header(conn1, "x-ratelimit-limit") == ["2"]
      assert get_resp_header(conn1, "x-ratelimit-remaining") == ["1"]

      build_conn() |> authed(plaintext) |> get("/api/v1/me")

      conn3 = build_conn() |> authed(plaintext) |> get("/api/v1/me")
      assert conn3.status == 429
      assert get_resp_header(conn3, "retry-after") != []
    end
  end

  describe "CORS" do
    test "preflight is answered without a token", %{conn: conn} do
      conn = options(conn, "/api/v1/me")
      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert [allow] = get_resp_header(conn, "access-control-allow-headers")
      assert allow =~ "authorization"
    end

    test "responses carry the open CORS header", %{conn: conn, plaintext: plaintext} do
      conn = conn |> authed(plaintext) |> get("/api/v1/me")
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end
end
