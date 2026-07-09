defmodule VutuvWeb.AlternateLoginCodeTest do
  use VutuvWeb.ConnCase, async: false

  # The issue #912 login path: a code from an authenticator app (TOTP) or from
  # a one-time code list works in the login PIN field instead of the emailed
  # PIN. Step 2 is a CSRF-anchored form (issue #759), so every submit here
  # goes through submit_with_csrf/3 like the PIN flow's own tests.

  import Ecto.Query

  alias Vutuv.Accounts.LoginPin
  alias Vutuv.LoginCodes

  # One address per test: the wrong-PIN lockout counter
  # (Accounts.record_login_pin_failure/1) is a per-email ETS window that
  # outlives a single test, so a shared address would leak failures across
  # tests. Tests read the address from the setup-provided context.
  setup do
    %{email: "codes-#{System.unique_integer([:positive])}@example.com"}
  end

  defp enrolled_user(email) do
    user = insert(:user, email_confirmed?: true)
    insert(:email, value: email, user: user)
    {:ok, pending} = LoginCodes.start_totp_enrollment(user)
    {:ok, _} = LoginCodes.confirm_totp(user, NimbleTOTP.verification_code(pending.secret))

    # The confirm stamped the current 30s window as used; backdate it so the
    # test can log in with a fresh code without waiting a real window out.
    LoginCodes.get_totp(user)
    |> Ecto.Changeset.change(last_used_at: DateTime.add(DateTime.utc_now(:second), -120))
    |> Repo.update!()

    {user, pending.secret}
  end

  # A 6-digit code that is neither the mailed PIN nor a currently valid TOTP
  # code, so a "wrong code" test can never fluke into a real one.
  defp wrong_code(pin, secret) do
    valid = [
      pin,
      NimbleTOTP.verification_code(secret),
      NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 30)
    ]

    Enum.find(["000000", "000001", "000002", "000003"], &(&1 not in valid))
  end

  test "a TOTP code works in the PIN field (CSRF enforced) and spends the mailed PIN",
       %{email: email} do
    {user, secret} = enrolled_user(email)

    conn = post(build_conn(), ~p"/login", session: %{"email" => email})
    assert html_response(conn, 200) =~ "Enter your PIN"
    assert conn.resp_body =~ "alternative-codes-hint"

    code = NimbleTOTP.verification_code(secret)
    conn = submit_with_csrf(conn, ~p"/login", %{"session" => %{"pin" => code}})

    assert redirected_to(conn) == ~p"/#{user}"
    assert get_session(conn, :user_id) == user.id

    # The PIN still sitting in the inbox must not stay live once the member
    # is in: an alternate-code login consumes it.
    pin_row = Repo.one(from(m in LoginPin, where: m.user_id == ^user.id and m.type == "login"))
    assert pin_row.consumed_at
  end

  test "a used TOTP code cannot log in a second time (replay)", %{email: email} do
    {user, secret} = enrolled_user(email)
    code = NimbleTOTP.verification_code(secret)

    conn = post(build_conn(), ~p"/login", session: %{"email" => email})
    conn = submit_with_csrf(conn, ~p"/login", %{"session" => %{"pin" => code}})
    assert get_session(conn, :user_id) == user.id

    # A fresh login attempt replaying the same code fails like a wrong PIN.
    conn = post(build_conn(), ~p"/login", session: %{"email" => email})
    conn = submit_with_csrf(conn, ~p"/login", %{"session" => %{"pin" => code}})
    refute get_session(conn, :user_id)
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Incorrect PIN"
  end

  test "a one-time list code works once, hyphen- and case-insensitively", %{email: email} do
    {user, _secret} = enrolled_user(email)
    [%{code: code} | _] = LoginCodes.generate_list_codes(user)

    conn = post(build_conn(), ~p"/login", session: %{"email" => email})
    conn = submit_with_csrf(conn, ~p"/login", %{"session" => %{"pin" => String.downcase(code)}})
    assert get_session(conn, :user_id) == user.id
    assert LoginCodes.unused_list_codes_count(user) == 9

    # The consumed code is spent for good.
    conn = post(build_conn(), ~p"/login", session: %{"email" => email})
    conn = submit_with_csrf(conn, ~p"/login", %{"session" => %{"pin" => code}})
    refute get_session(conn, :user_id)
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Incorrect PIN"
  end

  test "the emailed PIN keeps working for an enrolled member", %{email: email} do
    {user, _secret} = enrolled_user(email)

    conn = post(build_conn(), ~p"/login", session: %{"email" => email})
    conn = submit_with_csrf(conn, ~p"/login", %{"session" => %{"pin" => sent_pin()}})

    assert get_session(conn, :user_id) == user.id
  end

  test "wrong codes stay on the PIN flow's unchanged lockout budget", %{email: email} do
    {_user, secret} = enrolled_user(email)

    conn = post(build_conn(), ~p"/login", session: %{"email" => email})
    wrong = wrong_code(sent_pin(), secret)

    # Two wrong attempts read as a plain wrong PIN...
    for _ <- 1..2 do
      retry = submit_with_csrf(conn, ~p"/login", %{"session" => %{"pin" => wrong}})
      assert Phoenix.Flash.get(retry.assigns.flash, :error) == "Incorrect PIN"
      refute get_session(retry, :user_id)
    end

    # ...and the third trips the same lockout the PIN flow always had.
    locked = submit_with_csrf(conn, ~p"/login", %{"session" => %{"pin" => wrong}})
    assert Phoenix.Flash.get(locked.assigns.flash, :error) == "Too many incorrect attempts."
    refute get_session(locked, :user_id)
  end

  test "the PIN screen hint shows only to members with something enrolled", %{email: email} do
    {_user, _secret} = enrolled_user(email)

    plain = insert(:user, email_confirmed?: true)
    plain_value = "plain-member-#{System.unique_integer([:positive])}@example.com"
    insert(:email, value: plain_value, user: plain)

    enrolled_conn = post(build_conn(), ~p"/login", session: %{"email" => email})
    assert html_response(enrolled_conn, 200) =~ "alternative-codes-hint"

    plain_conn = post(build_conn(), ~p"/login", session: %{"email" => plain_value})
    refute html_response(plain_conn, 200) =~ "alternative-codes-hint"

    # An unknown address reads exactly like a member with nothing enrolled.
    unknown_conn = post(build_conn(), ~p"/login", session: %{"email" => "nobody@example.com"})
    refute html_response(unknown_conn, 200) =~ "alternative-codes-hint"
  end
end
