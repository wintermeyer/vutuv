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
      key = Base.encode32(totp.secret, padding: false)
      assert html =~ String.slice(key, 0, 4)

      # The key sits on its own line with a one-click copy whose clipboard
      # payload is the ungrouped Base32 (display spaces stripped).
      assert html =~ ~s(id="totp-manual-key")
      assert html =~ ~s(data-copy-text="#{key}")
      refute LoginCodes.totp_enabled?(user)
    end

    test "the setup link is copyable as text, not only as a QR code", %{conn: conn, user: user} do
      html = conn |> recycle() |> get(~p"/settings/totp/new") |> html_response(200)

      totp = LoginCodes.get_totp(user)
      uri = LoginCodes.otpauth_uri(user, totp)

      # Issue #1812: the URI carries issuer, account and key together, so a
      # password manager fills the whole entry in from one paste. Before this
      # it existed on the page only as the QR picture and as a link href, so
      # getting at it meant decoding our own QR code.
      assert html =~ ~s(data-copy-target="totp-setup-uri")

      # The field carries no data-copy-text, so app.js copies the element's own
      # text — assert on that text, not merely on the URI appearing somewhere
      # in the document, or the QR code's href alone would satisfy this.
      assert text_of(html, "#totp-setup-uri") == uri
    end

    test "the three ways to hand the secret over are translated", %{conn: conn} do
      # vutuv is a German site, so the new labels are asserted by name in
      # German: `gettext.extract --merge` fuzzy-fills a brand-new msgid with
      # some unrelated translation and nothing fails the build, so an English
      # assertion here would prove nothing about what a member reads.
      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/settings/totp/new")
        |> html_response(200)

      assert html =~ "Klappt das Scannen nicht?"
      assert html =~ "In der Authenticator-App öffnen"
      assert html =~ "Einrichtungs-Link kopieren"
      assert html =~ "Nur den Schlüssel kopieren"
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
