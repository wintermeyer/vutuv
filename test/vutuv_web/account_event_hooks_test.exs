defmodule VutuvWeb.AccountEventHooksTest do
  @moduledoc """
  The hooks that feed the account-activity log (issue #1087), driven through the
  real request paths rather than by calling `Vutuv.AccountEvents.record/3`
  directly — the point being that the chokepoints really fire, and that what
  reaches the table is what the log is allowed to hold (no PIN, no full email
  address, no muted word).
  """
  use VutuvWeb.ConnCase, async: false

  import Ecto.Query

  alias Vutuv.AccountEvents.AccountEvent
  alias Vutuv.Repo

  defp events(user, kind) do
    Repo.all(
      from(e in AccountEvent,
        where: e.user_id == ^user.id and e.kind == ^kind,
        order_by: [asc: e.inserted_at]
      )
    )
  end

  describe "signing in and out" do
    test "an emailed-PIN login is recorded with its factor and device, not its IP", %{
      conn: conn
    } do
      user = insert(:user, email_confirmed?: true)
      insert(:email, value: "hook-login@example.com", user: user)

      conn =
        conn
        |> Plug.Conn.put_req_header("user-agent", "Mozilla/5.0 (iPhone) Safari/604.1")
        |> login_via_pin("hook-login@example.com")

      assert redirected_to(conn)
      assert [event] = events(user, "signed_in")
      assert event.factor == "pin"
      assert event.device == "Safari on iPhone"
      refute Map.has_key?(event, :ip_address)
    end

    test "logging out is recorded too", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      delete(conn, ~p"/logout")

      assert [_signed_out] = events(user, "signed_out")
    end

    test "signing every other device out records how many went", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # A second device for this account, so the sweep has something to revoke.
      Vutuv.Sessions.start_session(user, Phoenix.ConnTest.build_conn(), alert: false)

      delete(conn, ~p"/settings/devices")

      assert [event] = events(user, "other_sessions_revoked")
      assert event.details["count"] == 1
    end
  end

  describe "identity" do
    test "a username change records both handles and the confirming factor", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      old_handle = user.username

      conn = post(conn, ~p"/settings/username", %{"user" => %{"username" => "hooked_handle"}})
      assert html_response(conn, 200)

      conn =
        post(conn, ~p"/settings/username/confirm", %{
          "username_confirmation" => %{"code" => sent_pin()}
        })

      assert redirected_to(conn) == ~p"/hooked_handle"
      assert [event] = events(user, "username_changed")
      assert event.details == %{"from" => old_handle, "to" => "hooked_handle"}
      assert event.factor == "pin"
    end

    test "a profile save records the field NAMES, never their values", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      put(conn, ~p"/settings/profile", %{
        "user" => %{"first_name" => "Renamed", "headline" => "A secret-ish tagline"}
      })

      assert [event] = events(user, "profile_updated")
      assert Enum.sort(event.details["fields"]) == ["first_name", "headline"]
      refute inspect(event.details) =~ "Renamed"
      refute inspect(event.details) =~ "secret-ish"
    end

    test "an added email address is stored MASKED", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/settings/emails", %{
          "email" => %{"value" => "second-address@example.com", "email_type" => "Work"}
        })

      assert html_response(conn, 200)

      conn =
        post(conn, ~p"/settings/emails/confirmation", %{
          "email_confirmation" => %{"pin" => sent_pin()}
        })

      assert redirected_to(conn)
      assert [event] = events(user, "email_added")
      assert event.details["email"] == "se***@example.com"
      refute event.details["email"] =~ "second-address@"
    end
  end

  describe "factors" do
    test "turning the authenticator app on and off is recorded, the secret never is", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      {:ok, pending} = Vutuv.LoginCodes.start_totp_enrollment(user)

      post(conn, ~p"/settings/totp", %{
        "totp" => %{"code" => NimbleTOTP.verification_code(pending.secret)}
      })

      assert [enabled] = events(user, "totp_enabled")
      assert enabled.details == %{}

      delete(conn, ~p"/settings/totp")
      assert [_disabled] = events(user, "totp_disabled")
    end

    test "a fresh one-time code list records the count, never a code", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post(conn, ~p"/settings/login_codes")

      assert [event] = events(user, "login_codes_generated")
      assert event.details["count"] > 0

      codes = Enum.map(Vutuv.LoginCodes.list_codes(user), & &1.code)
      refute Enum.any?(codes, &(inspect(event.details) =~ &1))
    end
  end

  describe "language & display" do
    test "saving a date format and a time zone records the field names, not the values", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)

      put(conn, ~p"/settings/language",
        user: %{"date_region" => "US", "time_zone" => "America/Denver"}
      )

      assert [event] = events(user, "preferences_changed")
      assert event.details["fields"] == ["date_region", "time_zone"]

      # A member's time zone is a coarse location, and this log outlives the
      # change by a year — the value must not be in it.
      refute inspect(event.details) =~ "America/Denver"
    end

    test "the other cards on the page record under the same kind", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      put(conn, ~p"/settings/maps", user: %{"default_map_service" => "apple"})
      put(conn, ~p"/settings/post_display", user: %{"post_lines_desktop" => "3"})

      assert [maps, posts] = events(user, "preferences_changed")
      assert maps.details["fields"] == ["default_map_service"]
      assert posts.details["fields"] == ["post_lines_desktop"]
    end

    # The way back was silent while the save was logged, which is the half of
    # the story a member checking "was that me?" most needs.
    test "a reset records the group it cleared", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      put(conn, ~p"/settings/language", user: %{"time_zone" => "UTC"})
      post(conn, ~p"/settings/region/reset")

      assert [_save, reset] = events(user, "preferences_changed")
      assert reset.details["fields"] == ["date_region", "time_zone"]
    end

    test "the visibility reset stays on its own page's kind", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post(conn, ~p"/settings/privacy/reset")

      assert [event] = events(user, "privacy_changed")
      assert event.details["fields"] == ["like_attribution?"]
      assert events(user, "preferences_changed") == []
    end
  end

  describe "privacy" do
    test "a visibility save records which switches were touched", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      put(conn, ~p"/settings/privacy", %{"user" => %{"noindex?" => "true"}})

      assert [event] = events(user, "privacy_changed")
      assert event.details["fields"] == ["noindex?"]
    end

    test "a fediverse save records both the participation state and the fields", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _on} = Vutuv.Accounts.update_user(user, %{"fediverse_followers?" => "true"})

      # No acknowledgement needed: this save leaves the take-part switch alone.
      put(conn, ~p"/settings/fediverse",
        user: %{"fediverse_followers?" => "true", "fediverse_reactions?" => "false"}
      )

      assert [event] = events(user, "fediverse_changed")
      assert event.details["enabled"] == true

      assert event.details["fields"] == ["fediverse_followers?", "fediverse_reactions?"]
    end

    test "a content filter records its kind, never the muted word", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post(conn, ~p"/settings/filters", %{
        "content_filter" => %{"kind" => "keyword", "pattern" => "unspeakable"}
      })

      assert [event] = events(user, "filter_added")
      assert event.details["filter_kind"] == "keyword"
      refute inspect(event.details) =~ "unspeakable"
    end

    test "blocking and unblocking a member records the public handle", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      target = insert(:user, username: "blockee-hook")

      post(conn, ~p"/blocks", %{"block" => %{"user_id" => target.id}})
      assert [blocked] = events(user, "member_blocked")
      assert blocked.details["handle"] == "blockee-hook"

      block = Vutuv.Social.get_block(user.id, target.id)
      delete(conn, ~p"/blocks/#{block.id}")
      assert [unblocked] = events(user, "member_unblocked")
      assert unblocked.details["handle"] == "blockee-hook"
    end
  end

  describe "data" do
    test "downloading the GDPR export is recorded", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = get(conn, ~p"/#{user}/export/download")
      assert response(conn, 200)

      assert [_event] = events(user, "data_exported")
    end
  end

  describe "somebody else acting on the account" do
    test "an admin freeze lands in the MEMBER's log, naming the admin", %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      member = insert(:user)

      post(conn, ~p"/admin/accounts/#{member.id}/freeze", %{"reason" => "spam"})

      assert [event] = events(member, "account_frozen")
      assert event.actor_user_id == admin.id
      assert event.factor == "admin"
      # The internal moderation reason stays out of a log the member reads.
      assert event.details == %{}
    end

    test "an admin force-rename lands in the member's log with both handles", %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      member = insert(:user, username: "unwanted-name")

      post(conn, ~p"/admin/usernames", %{"username_disable" => %{"value" => "unwanted-name"}})

      assert [event] = events(member, "username_changed")
      assert event.actor_user_id == admin.id
      assert event.details["from"] == "unwanted-name"
      assert event.details["to"] != "unwanted-name"
    end
  end
end
