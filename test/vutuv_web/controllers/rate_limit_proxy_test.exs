defmodule VutuvWeb.RateLimitProxyTest do
  @moduledoc """
  End-to-end guard for issues #799 / #837: behind the nginx reverse proxy the
  per-IP rate limiter must key on the real client address (from
  `X-Forwarded-For`, resolved by the endpoint's `RemoteIp` plug), not on the
  single loopback proxy hop every visitor shares. Before the fix, five logins
  site-wide in one window locked everyone else out.
  """
  use VutuvWeb.ConnCase, async: false

  setup do
    Vutuv.RateLimiter.reset()
    previous = Application.get_env(:vutuv, :rate_limit)
    # A tiny budget keeps the test fast; the window is long enough not to roll
    # over mid-test.
    Application.put_env(:vutuv, :rate_limit, enabled: true, limit: 2, window_ms: 60_000)
    on_exit(fn -> Application.put_env(:vutuv, :rate_limit, previous) end)
    :ok
  end

  # A passkey challenge with no email is the cheapest rate-limited endpoint: it
  # mints a WebAuthn challenge and answers JSON without sending mail or touching
  # the account tables, and it throttles on the per-IP key alone (no email
  # identity), so it isolates IP scoping through the full endpoint pipeline.
  defp challenge(conn, forwarded_ip) do
    conn
    # Simulate the loopback proxy hop nginx connects from...
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    # ...carrying the real visitor address in X-Forwarded-For.
    |> put_req_header("x-forwarded-for", forwarded_ip)
    # ConnTest recycles a fresh conn on dispatch and drops X-Forwarded-For; mark
    # it recycled so the header survives (same trick as submit_with_csrf/3).
    |> Plug.Conn.put_private(:phoenix_recycled, true)
    |> post(~p"/login/passkey/challenge", %{})
  end

  test "the per-IP limiter scopes by the forwarded client IP, not the shared proxy hop",
       %{conn: conn} do
    # One real client spends its budget of 2...
    assert challenge(conn, "203.0.113.10").status == 200
    assert challenge(conn, "203.0.113.10").status == 200
    assert challenge(conn, "203.0.113.10").status == 429

    # ...but a different real client behind the same proxy still has its full
    # budget. Before the fix both collapsed onto 127.0.0.1 and this was a 429.
    assert challenge(conn, "198.51.100.20").status == 200
  end

  test "a spoofed X-Forwarded-For prefix cannot steal another client's budget",
       %{conn: conn} do
    # nginx appends the real peer, so the header reads "<spoof>, <real client>".
    # RemoteIp takes the right-most non-proxy hop, so the key is the real client
    # and the attacker cannot exhaust a victim's bucket by forging the prefix.
    assert challenge(conn, "203.0.113.30").status == 200
    assert challenge(conn, "8.8.8.8, 203.0.113.30").status == 200
    assert challenge(conn, "203.0.113.30").status == 429
  end
end
