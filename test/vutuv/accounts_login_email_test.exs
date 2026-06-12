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

  describe "record_login_pin_failure/1 (the per-identity lockout)" do
    setup do
      Vutuv.RateLimiter.reset()
      :ok
    end

    test "an unknown address locks out after the same number of wrong PINs as a real one" do
      # A real account: the per-PIN DB counter locks on the third wrong PIN.
      user = insert(:user, activated?: true)
      insert(:email, value: "real@example.com", user: user)
      Vutuv.Accounts.gen_pin_for(user, "login")

      assert {:error, _} = Vutuv.Accounts.check_pin("real@example.com", "000000", "login")
      assert {:error, _} = Vutuv.Accounts.check_pin("real@example.com", "000000", "login")
      assert :lockout = Vutuv.Accounts.check_pin("real@example.com", "000000", "login")

      # An unknown address has no DB row to count against, so the per-identity
      # counter must reach the same verdict on the same attempt.
      assert :ok = Vutuv.Accounts.record_login_pin_failure("ghost@example.com")
      assert :ok = Vutuv.Accounts.record_login_pin_failure("ghost@example.com")
      assert :locked = Vutuv.Accounts.record_login_pin_failure("ghost@example.com")
    end

    test "is case- and identity-scoped" do
      assert :ok = Vutuv.Accounts.record_login_pin_failure("a@example.com")
      assert :ok = Vutuv.Accounts.record_login_pin_failure("A@example.com")
      # A different identity has its own budget.
      assert :ok = Vutuv.Accounts.record_login_pin_failure("b@example.com")
      # The first identity (case-insensitive) is now on its third strike.
      assert :locked = Vutuv.Accounts.record_login_pin_failure("a@example.com")
    end
  end
end
