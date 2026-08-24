defmodule VutuvWeb.ApiV2Test do
  use VutuvWeb.ConnCase

  alias Vutuv.ApiAuth

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()
    user = insert_activated_user()

    {:ok, plaintext, token} =
      ApiAuth.create_pat(user, %{"name" => "Test", "scopes" => ["profile:read"]})

    {:ok, conn: conn, user: user, plaintext: plaintext, token: token}
  end

  describe "authentication" do
    test "no token is a 401 problem with WWW-Authenticate", %{conn: conn} do
      conn = get(conn, "/api/2.0/me")
      assert conn.status == 401
      assert %{"title" => "Unauthorized", "status" => 401} = api_problem(conn)
      assert [www] = get_resp_header(conn, "www-authenticate")
      assert www =~ "Bearer"
    end

    test "an invalid token is a 401", %{conn: conn} do
      conn = conn |> authed("vutuv_pat_bogus") |> get("/api/2.0/me")
      assert conn.status == 401
    end

    test "a revoked token is a 401 on the very next request", %{
      conn: conn,
      plaintext: plaintext,
      token: token
    } do
      assert authed(conn, plaintext) |> get("/api/2.0/me") |> Map.fetch!(:status) == 200

      ApiAuth.revoke_token!(token)

      conn = build_conn() |> authed(plaintext) |> get("/api/2.0/me")
      assert conn.status == 401
      assert api_problem(conn)["detail"] =~ "revoked"
    end

    test "unknown API paths are a JSON 404, not an HTML page", %{
      conn: conn,
      plaintext: plaintext
    } do
      conn = conn |> authed(plaintext) |> get("/api/2.0/nonexistent")
      assert conn.status == 404
      assert %{"status" => 404} = api_problem(conn)
    end
  end

  describe "scopes" do
    test "a token without the needed scope gets a 403 naming it", %{conn: conn, user: user} do
      {:ok, plaintext, _} = ApiAuth.create_pat(user, %{"name" => "n", "scopes" => ["posts:read"]})

      conn = conn |> authed(plaintext) |> get("/api/2.0/me")
      assert conn.status == 403
      assert api_problem(conn)["required_scope"] == "profile:read"
    end

    test "profile:write implies profile:read", %{conn: conn, user: user} do
      {:ok, plaintext, _} =
        ApiAuth.create_pat(user, %{"name" => "n", "scopes" => ["profile:write"]})

      conn = conn |> authed(plaintext) |> get("/api/2.0/me")
      assert conn.status == 200
    end
  end

  describe "GET /api/2.0/me" do
    test "returns the caller's profile through their own eyes", %{
      conn: conn,
      user: user,
      plaintext: plaintext
    } do
      insert(:email, user: user, public?: false, value: "private@example.com")

      conn = conn |> authed(plaintext) |> get("/api/2.0/me")
      body = json_response(conn, 200)

      assert body["username"] == user.username
      # Emails are typed maps (schema_version 2), matching phone_numbers.
      assert Enum.any?(body["emails"], &(&1["value"] == "private@example.com"))
    end
  end

  describe "GET /api/2.0/users/:slug" do
    test "returns another member's anonymous-public view", %{conn: conn, plaintext: plaintext} do
      other = insert_activated_user()
      insert(:email, user: other, public?: false, value: "private@example.com")
      insert(:email, user: other, public?: true, value: "public@example.com")

      conn = conn |> authed(plaintext) |> get("/api/2.0/users/#{other.username}")
      body = json_response(conn, 200)

      assert body["username"] == other.username
      assert Enum.any?(body["emails"], &(&1["value"] == "public@example.com"))
      refute Enum.any?(body["emails"], &(&1["value"] == "private@example.com"))
    end

    test "unactivated and moderation-hidden accounts 404 for strangers", %{
      conn: conn,
      plaintext: plaintext
    } do
      unactivated = insert(:user, email_confirmed?: false)

      conn1 = conn |> authed(plaintext) |> get("/api/2.0/users/#{unactivated.username}")
      assert conn1.status == 404

      frozen = insert_activated_user(frozen_at: NaiveDateTime.utc_now(:second))
      conn2 = build_conn() |> authed(plaintext) |> get("/api/2.0/users/#{frozen.username}")
      assert conn2.status == 404
    end

    test "a frozen profile stays visible to its owner, like the HTML page", %{conn: conn} do
      owner = insert_activated_user(frozen_at: NaiveDateTime.utc_now(:second))

      {:ok, plaintext, _} =
        ApiAuth.create_pat(owner, %{"name" => "n", "scopes" => ["profile:read"]})

      conn = conn |> authed(plaintext) |> get("/api/2.0/users/#{owner.username}")
      assert conn.status == 200
    end
  end

  describe "rate limiting" do
    @window_ms 60_000

    test "per-token limit with headers, then 429", %{conn: conn, plaintext: plaintext} do
      Application.put_env(:vutuv, :api_v2_rate_limit, {2, @window_ms})
      on_exit(fn -> Application.delete_env(:vutuv, :api_v2_rate_limit) end)

      {conn1, conn3} = three_requests(conn, plaintext)

      assert conn1.status == 200
      assert get_resp_header(conn1, "x-ratelimit-limit") == ["2"]
      assert get_resp_header(conn1, "x-ratelimit-remaining") == ["1"]

      assert conn3.status == 429
      assert get_resp_header(conn3, "retry-after") != []
    end

    # `Vutuv.RateLimiter` buckets by `div(now, window_ms)`, a **fixed** wall-clock
    # window rather than a sliding one, so three requests that straddle the top of
    # the window land in two different buckets: the counter restarts and the third
    # request is not limited. That is not hypothetical — it turned CI red on
    # 2026-08-04 at exactly 16:45:00.03, on a branch that touches nothing in this
    # path, and it passes locally every time.
    #
    # So the window is checked around the requests rather than asserted into. A
    # roll means the run was meaningless, not that the limiter is broken, and one
    # retry is enough: the three requests take milliseconds and cannot straddle
    # two boundaries in a row.
    #
    # **The retry has to empty the bucket first, and that is the whole point of
    # this line.** A roll leaves the requests made *after* it sitting in the new
    # bucket — the very bucket the next attempt starts counting in — so with a
    # limit of two, a roll between the first and second request left two hits
    # behind and the retry's own first request was refused with a 429. The test
    # then failed asserting `conn1.status == 200`, which reads as the limiter
    # letting nothing through rather than as the retry poisoning itself. Seen on
    # 2026-08-04 and again on 2026-08-24, both times on a branch that touches
    # nothing in this path. The token may stay the same; only its count must go.
    defp three_requests(conn, plaintext, attempt \\ 1) do
      Vutuv.RateLimiter.reset()
      before = current_window()
      conn1 = conn |> authed(plaintext) |> get("/api/2.0/me")
      build_conn() |> authed(plaintext) |> get("/api/2.0/me")
      conn3 = build_conn() |> authed(plaintext) |> get("/api/2.0/me")

      cond do
        current_window() == before -> {conn1, conn3}
        attempt < 3 -> three_requests(build_conn(), plaintext, attempt + 1)
        true -> flunk("the rate-limit window rolled on every attempt")
      end
    end

    defp current_window, do: div(System.system_time(:millisecond), @window_ms)
  end

  describe "CORS" do
    test "preflight is answered without a token", %{conn: conn} do
      conn = options(conn, "/api/2.0/me")
      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert [allow] = get_resp_header(conn, "access-control-allow-headers")
      assert allow =~ "authorization"
    end

    test "responses carry the open CORS header", %{conn: conn, plaintext: plaintext} do
      conn = conn |> authed(plaintext) |> get("/api/2.0/me")
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end
end
