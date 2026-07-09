defmodule VutuvWeb.TotpControllerTest do
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.LoginCodes

  # The authenticator-app enrolment (issue #912): /settings/totp/new shows the
  # QR code, POST /settings/totp confirms with a first code, DELETE turns it
  # off. All owner-only under the login-required /settings scope.

  describe "access control" do
    test "the setup page requires a login", %{conn: conn} do
      assert conn |> get(~p"/settings/totp/new") |> redirected_to() == "/"
    end
  end

  describe "setup" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, %{conn: conn, user: user}}
    end

    test "the setup page shows the QR code and the manual key", %{conn: conn, user: user} do
      html = conn |> recycle() |> get(~p"/settings/totp/new") |> html_response(200)

      assert html =~ "totp-qr"
      assert html =~ "totp-confirm-form"
      assert html =~ "<svg"

      # The same-device enrolment link (you can't scan your own screen): the
      # otpauth:// scheme must survive HEEx attribute escaping, or iOS/Android
      # can't hand the secret to the authenticator app.
      assert html =~ ~s(id="totp-same-device")
      assert html =~ ~s(href="otpauth://totp/)

      totp = LoginCodes.get_totp(user)
      assert html =~ totp.secret |> Base.encode32(padding: false) |> String.slice(0, 4)
      refute LoginCodes.totp_enabled?(user)
    end

    test "confirming with the current app code turns the enrolment on", %{
      conn: conn,
      user: user
    } do
      conn = conn |> recycle() |> get(~p"/settings/totp/new")
      totp = LoginCodes.get_totp(user)

      conn =
        conn
        |> recycle()
        |> post(~p"/settings/totp",
          totp: %{"code" => NimbleTOTP.verification_code(totp.secret)}
        )

      assert redirected_to(conn) == ~p"/settings/security"
      assert LoginCodes.totp_enabled?(user)

      # The security page now offers to turn it off, and the setup URL
      # bounces (an established secret is never silently replaced).
      html = conn |> recycle() |> get(~p"/settings/security") |> html_response(200)
      assert html =~ "Turned on."

      assert conn |> recycle() |> get(~p"/settings/totp/new") |> redirected_to() ==
               ~p"/settings/security"
    end

    test "a wrong code re-renders the setup with the same secret", %{conn: conn, user: user} do
      conn = conn |> recycle() |> get(~p"/settings/totp/new")
      totp = LoginCodes.get_totp(user)

      conn = conn |> recycle() |> post(~p"/settings/totp", totp: %{"code" => "000000"})

      assert html_response(conn, 200) =~ "totp-confirm-form"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't match"
      refute LoginCodes.totp_enabled?(user)
      # The pending secret survives the retry, so the scanned QR stays valid.
      assert LoginCodes.get_totp(user).secret == totp.secret
    end

    test "confirming without a pending enrolment sends back to the setup page", %{conn: conn} do
      conn = conn |> recycle() |> post(~p"/settings/totp", totp: %{"code" => "123456"})
      assert redirected_to(conn) == ~p"/settings/totp/new"
    end
  end

  describe "turn off" do
    test "removes the enrolment and returns to the security page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, pending} = LoginCodes.start_totp_enrollment(user)
      {:ok, _} = LoginCodes.confirm_totp(user, NimbleTOTP.verification_code(pending.secret))
      assert LoginCodes.totp_enabled?(user)

      conn = conn |> recycle() |> delete(~p"/settings/totp")

      assert redirected_to(conn) == ~p"/settings/security"
      refute LoginCodes.totp_enabled?(user)
    end
  end
end
