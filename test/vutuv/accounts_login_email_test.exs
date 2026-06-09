defmodule Vutuv.AccountsLoginEmailTest do
  use VutuvWeb.ConnCase, async: false
  import Swoosh.TestAssertions

  setup do
    %{conn: build_conn() |> init_test_session(%{})}
  end

  test "login_by_email delivers a login email to a known address", %{conn: conn} do
    user = insert(:user, activated?: true)
    insert(:email, value: "login-flow@example.com", user: user)

    assert {:ok, _conn} = Vutuv.Accounts.login_by_email(conn, "login-flow@example.com")
    assert_email_sent()
  end

  test "login_by_email with an unknown address sends nothing", %{conn: conn} do
    assert {:error, :not_found, _conn} =
             Vutuv.Accounts.login_by_email(conn, "nobody@example.com")

    assert_no_email_sent()
  end
end
