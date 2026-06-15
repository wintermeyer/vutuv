defmodule Vutuv.SessionsTest do
  @moduledoc """
  The server-side session store behind the signed-in-devices list (issue #794)
  and the new-device security email (issue #786).
  """
  use Vutuv.DataCase, async: false

  import Swoosh.TestAssertions

  alias Vutuv.Sessions
  alias Vutuv.Sessions.UserSession

  @chrome_mac "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
  @safari_iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

  defp conn_with(ua, ip \\ {203, 0, 113, 7}) do
    Plug.Test.conn(:get, "/")
    |> Map.put(:remote_ip, ip)
    |> Plug.Conn.put_req_header("user-agent", ua)
  end

  describe "start_session/3 and active_session/1" do
    test "mints a row, stores only the hash, and is found by the raw token" do
      user = insert(:user)
      {token, session} = Sessions.start_session(user, conn_with(@chrome_mac), alert: false)

      assert %UserSession{} = session
      assert session.user_id == user.id
      assert session.user_agent == @chrome_mac
      assert session.last_seen_at
      # The raw token is never stored — only its SHA-256.
      assert session.token_hash == Sessions.hash_token(token)
      refute session.token_hash == token

      assert %UserSession{id: id} = Sessions.active_session(token)
      assert id == session.id
    end

    test "active_session/1 returns nil for an unknown or revoked token" do
      user = insert(:user)
      {token, session} = Sessions.start_session(user, conn_with(@chrome_mac), alert: false)

      assert Sessions.active_session("nope") == nil

      Sessions.revoke(session)
      assert Sessions.active_session(token) == nil
    end
  end

  describe "touch/1" do
    test "bumps last_seen_at only once the resolution window has passed" do
      user = insert(:user)
      {_token, session} = Sessions.start_session(user, conn_with(@chrome_mac), alert: false)

      # Just-seen: a second touch is a no-op (no hot-row write).
      assert Sessions.touch(session).last_seen_at == session.last_seen_at

      stale = %{session | last_seen_at: DateTime.add(session.last_seen_at, -120, :second)}
      touched = Sessions.touch(stale)
      assert DateTime.compare(touched.last_seen_at, stale.last_seen_at) == :gt
    end
  end

  describe "list_active/1 and get_session/2" do
    test "lists only the user's own active sessions, most-recent first" do
      user = insert(:user)
      other = insert(:user)
      {_t1, s1} = Sessions.start_session(user, conn_with(@chrome_mac), alert: false)
      {_t2, s2} = Sessions.start_session(user, conn_with(@safari_iphone), alert: false)
      {_t3, s3} = Sessions.start_session(other, conn_with(@chrome_mac), alert: false)

      ids = Sessions.list_active(user) |> Enum.map(& &1.id)
      assert s1.id in ids
      assert s2.id in ids
      refute s3.id in ids

      Sessions.revoke(s1)
      refute s1.id in (Sessions.list_active(user) |> Enum.map(& &1.id))
    end

    test "get_session/2 is scoped to the owner and safe on a bad id" do
      user = insert(:user)
      other = insert(:user)
      {_t, session} = Sessions.start_session(user, conn_with(@chrome_mac), alert: false)

      assert Sessions.get_session(user, session.id).id == session.id
      assert Sessions.get_session(other, session.id) == nil
      assert Sessions.get_session(user, "not-a-uuid") == nil
    end
  end

  describe "revoke/1" do
    test "marks the row revoked and disconnects that session's live sockets" do
      user = insert(:user)
      {_token, session} = Sessions.start_session(user, conn_with(@chrome_mac), alert: false)

      VutuvWeb.Endpoint.subscribe(Sessions.socket_id(session))
      revoked = Sessions.revoke(session)

      assert revoked.revoked_at
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end

  describe "revoke_all_except/2" do
    test "revokes every other session and keeps the current one" do
      user = insert(:user)
      {_t1, current} = Sessions.start_session(user, conn_with(@chrome_mac), alert: false)
      {_t2, other1} = Sessions.start_session(user, conn_with(@safari_iphone), alert: false)
      {_t3, other2} = Sessions.start_session(user, conn_with(@chrome_mac), alert: false)

      VutuvWeb.Endpoint.subscribe(Sessions.socket_id(other1))

      assert Sessions.revoke_all_except(user, current.id) == 2

      active_ids = Sessions.list_active(user) |> Enum.map(& &1.id)
      assert active_ids == [current.id]
      refute other2.id in active_ids
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end

  describe "device_summary/1" do
    test "summarizes common browser/OS combinations" do
      assert Sessions.device_summary(@chrome_mac) == "Chrome on macOS"
      assert Sessions.device_summary(@safari_iphone) == "Safari on iPhone"

      assert Sessions.device_summary("Mozilla/5.0 (Windows NT 10.0) Firefox/125.0") ==
               "Firefox on Windows"

      assert Sessions.device_summary(nil) == "Unknown device"
      assert Sessions.device_summary("") == "Unknown device"
    end

    test "mobile?/1 picks phones/tablets for the glyph" do
      assert Sessions.mobile?(@safari_iphone)
      assert Sessions.mobile?("Mozilla/5.0 (Linux; Android 14) Mobile")
      refute Sessions.mobile?(@chrome_mac)
      refute Sessions.mobile?(nil)
    end
  end

  describe "alert_reasons/3 (issue #786 detection)" do
    test "the very first login is never noteworthy" do
      user = insert(:user)
      assert Sessions.alert_reasons(user, @chrome_mac, nil) == []
    end

    test "a returning login from a known device, nothing else active, is quiet" do
      user = insert(:user)
      {_t, s} = Sessions.start_session(user, conn_with(@chrome_mac), alert: false)
      Sessions.revoke(s)

      assert Sessions.alert_reasons(user, @chrome_mac, nil) == []
    end

    test "a login from a never-seen device is a new device" do
      user = insert(:user)
      {_t, s} = Sessions.start_session(user, conn_with(@chrome_mac), alert: false)
      Sessions.revoke(s)

      assert Sessions.alert_reasons(user, @safari_iphone, nil) == [:new_device]
    end

    test "a second active session is flagged concurrent" do
      user = insert(:user)
      Sessions.start_session(user, conn_with(@chrome_mac), alert: false)

      # Same device still active, so not new — but concurrent.
      assert Sessions.alert_reasons(user, @chrome_mac, nil) == [:concurrent]
    end

    test "suspicious_location stays dormant without geo data" do
      user = insert(:user)
      {_t, s} = Sessions.start_session(user, conn_with(@chrome_mac), alert: false)
      Sessions.revoke(s)

      # No prior location was ever recorded (no geo provider), so there is
      # nothing to be suspicious about even from a brand-new device.
      assert Sessions.alert_reasons(user, @safari_iphone, "Tokyo, JP") == [:new_device]
    end
  end

  describe "security alert email (issue #786)" do
    test "a login from a new device mails the owner; the first login does not" do
      user = insert(:user, emails: [build(:email)])

      # First ever login: silent.
      Sessions.start_session(user, conn_with(@chrome_mac))
      refute_received {:email, _}

      # New device: the owner is warned, with a link to their devices page.
      Sessions.start_session(user, conn_with(@safari_iphone))

      assert_email_sent(fn email ->
        assert email.subject =~ "New sign-in"
        assert email.text_body =~ "Safari on iPhone"
        assert email.text_body =~ "/settings"
      end)
    end

    test "a merely concurrent login (same device) sends no email" do
      user = insert(:user, emails: [build(:email)])
      Sessions.start_session(user, conn_with(@chrome_mac))
      Sessions.start_session(user, conn_with(@chrome_mac))

      refute_received {:email, _}
    end
  end
end
