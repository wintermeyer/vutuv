defmodule VutuvWeb.Plug.EnsureActivatedTest do
  use VutuvWeb.ConnCase, async: true

  # Regression: the error plugs rendered VutuvWeb.ErrorView, which no longer
  # exists under Phoenix 1.8 (it is VutuvWeb.ErrorHTML), so the 404 path
  # raised instead of returning a 404. An unactivated user's profile goes
  # through EnsureActivated and must return a clean 404.
  test "an unactivated user's profile returns 404, not a crash" do
    insert(:user, username: "unactivated-user", email_confirmed?: false)

    conn = get(build_conn(), "/unactivated-user")

    assert conn.status == 404
    assert conn.resp_body =~ ~r/not found/i
  end

  # Issue #812: a real-but-withheld account must not masquerade as 404. A
  # reversible hold (frozen / suspended / unreachable) is 403 Forbidden; a
  # permanent deactivation is 410 Gone; only a never-activated registration
  # keeps the anti-enumeration 404.
  describe "withheld status per moderation state" do
    test "a frozen profile returns 403 to an anonymous viewer" do
      insert(:activated_user,
        username: "held-account",
        frozen_at: NaiveDateTime.utc_now(:second)
      )

      conn = get(build_conn(), "/held-account")

      assert conn.status == 403
      assert conn.resp_body =~ "currently unavailable"
      # Must not reveal *why* it is unavailable.
      refute conn.resp_body =~ ~r/frozen|suspended|deactivated/i
    end

    test "a suspended profile returns 403" do
      future = NaiveDateTime.add(NaiveDateTime.utc_now(:second), 7 * 86_400)
      insert(:activated_user, username: "suspended-user", suspended_until: future)

      conn = get(build_conn(), "/suspended-user")

      assert conn.status == 403
    end

    test "an unreachable profile returns 403" do
      insert(:activated_user,
        username: "unreachable-user",
        unreachable_at: NaiveDateTime.utc_now(:second)
      )

      conn = get(build_conn(), "/unreachable-user")

      assert conn.status == 403
    end

    test "a deactivated profile returns 410 Gone" do
      insert(:activated_user,
        username: "deactivated-user",
        deactivated_at: NaiveDateTime.utc_now(:second)
      )

      conn = get(build_conn(), "/deactivated-user")

      assert conn.status == 410
      assert conn.resp_body =~ "currently unavailable"
    end

    test "a never-activated account that is also frozen still returns 404 (anti-enumeration wins)" do
      insert(:user,
        username: "unconfirmed-frozen",
        email_confirmed?: false,
        frozen_at: NaiveDateTime.utc_now(:second)
      )

      conn = get(build_conn(), "/unconfirmed-frozen")

      assert conn.status == 404
    end

    test "an active profile still renders (200)" do
      insert(:activated_user, username: "active-user")

      conn = get(build_conn(), "/active-user")

      assert conn.status == 200
    end
  end

  # The agent-format siblings share EnsureActivated and must report the *same*
  # status as the HTML page, so HTML and .md/.json/.vcf stay consistent.
  describe "agent-format siblings carry the same status" do
    test "a frozen profile's .json and .md return 403" do
      insert(:activated_user,
        username: "frozen-sibling",
        frozen_at: NaiveDateTime.utc_now(:second)
      )

      assert get(build_conn(), "/frozen-sibling.json").status == 403
      assert get(build_conn(), "/frozen-sibling.md").status == 403
    end

    test "a deactivated profile's .json returns 410" do
      insert(:activated_user,
        username: "gone-sibling",
        deactivated_at: NaiveDateTime.utc_now(:second)
      )

      assert get(build_conn(), "/gone-sibling.json").status == 410
    end
  end
end
