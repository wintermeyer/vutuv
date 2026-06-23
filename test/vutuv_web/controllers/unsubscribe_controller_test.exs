defmodule VutuvWeb.UnsubscribeControllerTest do
  @moduledoc """
  The unsubscribe endpoint behind the unread-message email's footer link and
  its `List-Unsubscribe` header (RFC 8058 one-click). The signed token is the
  only authorization: no login, no session — and deliberately no CSRF check,
  because mail providers POST the one-click form without ever rendering a
  page. Anything but a valid token 404s.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias VutuvWeb.UnsubscribeToken

  setup %{conn: conn} do
    user = insert(:activated_user)
    {:ok, conn: conn, user: user, token: UnsubscribeToken.sign(user)}
  end

  defp reload(user), do: Repo.get(User, user.id)

  test "GET shows the confirmation page without touching the setting", %{
    conn: conn,
    user: user,
    token: token
  } do
    conn = get(conn, ~p"/unsubscribe/#{token}")

    assert html_response(conn, 200) =~ "@#{user.username}"
    assert reload(user).notification_emails?
  end

  test "POST switches notification emails off", %{conn: conn, user: user, token: token} do
    conn = post(conn, ~p"/unsubscribe/#{token}")

    assert html_response(conn, 200) =~ "@#{user.username}"
    refute reload(user).notification_emails?
  end

  test "the one-click POST succeeds without a session and with CSRF enforcement on", %{
    user: user,
    token: token
  } do
    # Mail providers POST `List-Unsubscribe=One-Click` with no cookies and no
    # CSRF token. ConnTest normally skips CSRF wholesale (issue #759), so
    # re-enable enforcement to prove the route really is exempt.
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
      |> post(~p"/unsubscribe/#{token}", %{"List-Unsubscribe" => "One-Click"})

    assert conn.status == 200
    refute reload(user).notification_emails?
  end

  test "POST is idempotent", %{conn: conn, user: user, token: token} do
    assert post(conn, ~p"/unsubscribe/#{token}").status == 200
    assert post(conn, ~p"/unsubscribe/#{token}").status == 200
    refute reload(user).notification_emails?
  end

  test "a tampered token 404s and changes nothing", %{conn: conn, user: user} do
    for bad <- ["garbage", UnsubscribeToken.sign(user) <> "x"] do
      assert get(conn, ~p"/unsubscribe/#{bad}").status == 404
      assert post(conn, ~p"/unsubscribe/#{bad}").status == 404
    end

    assert reload(user).notification_emails?
  end

  test "a token for a since-deleted account 404s", %{conn: conn, user: user, token: token} do
    _ = Vutuv.Accounts.delete_user(user)

    assert post(conn, ~p"/unsubscribe/#{token}").status == 404
  end

  test "a newsletter token names the newsletter and switches it off", %{conn: conn} do
    user = insert(:activated_user)
    token = UnsubscribeToken.sign(user, :newsletter_emails?)

    assert get(conn, ~p"/unsubscribe/#{token}") |> html_response(200) =~ "the vutuv newsletter"
    assert post(conn, ~p"/unsubscribe/#{token}") |> html_response(200) =~ "the vutuv newsletter"
    refute reload(user).newsletter_emails?
  end

  test "a per-type token switches only the named preference off", %{conn: conn} do
    user = insert(:activated_user, email_on_follower?: true, email_on_endorsement?: true)
    token = UnsubscribeToken.sign(user, :email_on_follower?)

    assert post(conn, ~p"/unsubscribe/#{token}").status == 200

    updated = reload(user)
    refute updated.email_on_follower?
    # The other preferences are left exactly as they were.
    assert updated.email_on_endorsement?
    assert updated.notification_emails?
  end

  test "a token naming a non-preference column 404s and changes nothing", %{conn: conn} do
    user = insert(:activated_user)
    # admin? is a real column but not in the email-preference allowlist, so a
    # token may never name it; the capability is locked to the four prefs.
    token = UnsubscribeToken.sign(user, :admin?)

    assert post(conn, ~p"/unsubscribe/#{token}").status == 404
    refute reload(user).admin?
  end
end
