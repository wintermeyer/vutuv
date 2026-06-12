defmodule Vutuv.AccountsLoginEmailTest do
  use VutuvWeb.ConnCase, async: false
  import Swoosh.TestAssertions

  setup do
    %{conn: build_conn() |> init_test_session(%{})}
  end

  @pin_cookie "_vutuv_login_pin"

  test "login_by_email delivers a login email to a known address", %{conn: conn} do
    user = insert(:user, activated?: true)
    insert(:email, value: "login-flow@example.com", user: user)

    assert {:ok, returned} = Vutuv.Accounts.login_by_email(conn, "login-flow@example.com")
    assert Map.has_key?(returned.resp_cookies, @pin_cookie)
    assert_email_sent()
  end

  test "an unknown address is indistinguishable from a known one but mails nothing", %{
    conn: conn
  } do
    # Same {:ok, conn} with the pending-identity cookie set as a known
    # address gets, so the response is no account-enumeration oracle — but
    # no PIN is mailed to an address without an account.
    assert {:ok, returned} = Vutuv.Accounts.login_by_email(conn, "nobody@example.com")
    assert Map.has_key?(returned.resp_cookies, @pin_cookie)
    assert_no_email_sent()
  end
end
