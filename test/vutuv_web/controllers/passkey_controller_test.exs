defmodule VutuvWeb.PasskeyControllerTest do
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Credentials

  # The browser WebAuthn ceremony can't run in the test adapter, so these cover
  # the web layer around it: owner gating, that the challenge endpoints answer
  # JSON and survive CSRF, that a bogus assertion is refused without logging
  # anyone in, and that removal works. The crypto round-trip is the real-browser
  # smoke test (issue #795).

  describe "GET /login (passkey affordance)" do
    test "offers the passkey sign-in button", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)

      assert html =~ "data-webauthn-login"
      assert html =~ ~s(data-challenge-url="#{~p"/login/passkey/challenge"}")
      assert html =~ "Sign in with a passkey"
    end
  end

  describe "POST /login/passkey/challenge" do
    test "returns authentication options and stores the challenge in the session", %{conn: conn} do
      conn = post(conn, ~p"/login/passkey/challenge")

      body = json_response(conn, 200)
      assert body["rpId"] == "localhost"
      assert {:ok, _} = Base.url_decode64(body["challenge"], padding: false)
      assert %Wax.Challenge{} = get_session(conn, :webauthn_auth_challenge)
    end
  end

  describe "POST /login/passkey (verification)" do
    test "a bogus assertion is refused and logs nobody in", %{conn: conn} do
      # Mint a challenge first, then submit a made-up assertion against it.
      conn = post(conn, ~p"/login/passkey/challenge")
      assert json_response(conn, 200)

      conn =
        conn
        |> recycle()
        |> post(~p"/login/passkey", %{
          "rawId" => b64(:crypto.strong_rand_bytes(16)),
          "authenticatorData" => b64("authdata"),
          "signature" => b64("signature"),
          "clientDataJSON" => b64("{}")
        })

      assert %{"ok" => false} = json_response(conn, 422)
      refute get_session(conn, :user_id)
    end

    test "an expired/absent challenge is a clean error", %{conn: conn} do
      conn = post(conn, ~p"/login/passkey", %{"rawId" => b64("x")})
      assert %{"ok" => false} = json_response(conn, 422)
      refute get_session(conn, :user_id)
    end
  end

  describe "enrolment access control" do
    test "a logged-out visitor cannot reach the enrolment endpoints", %{conn: conn} do
      # /settings is login-required; an anonymous POST is turned away before
      # any passkey code runs. (There is no foreign-member case any more: the
      # user-agnostic URL always operates on whoever is signed in.)
      assert conn |> post(~p"/settings/passkeys/challenge") |> redirected_to() == "/"
    end
  end

  describe "POST /settings/passkeys/challenge (owner)" do
    test "returns registration options and stores the challenge", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = conn |> recycle() |> post(~p"/settings/passkeys/challenge")

      body = json_response(conn, 200)
      assert body["rp"]["id"] == "localhost"
      assert body["user"]["name"] == user.username
      assert %Wax.Challenge{} = get_session(conn, :webauthn_reg_challenge)
    end

    test "the challenge endpoint survives CSRF enforcement", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      # submit_with_csrf scrapes the token from a rendered <form>; the security
      # page carries none with a single session, so grab it from the
      # preferences page (same session, same token).
      conn = get(conn, ~p"/settings/preferences")

      conn = submit_with_csrf(conn, ~p"/settings/passkeys/challenge", %{})
      assert json_response(conn, 200)
    end
  end

  describe "POST /settings/passkeys (create)" do
    test "a bogus attestation is refused and persists nothing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      conn = conn |> recycle() |> post(~p"/settings/passkeys/challenge")
      assert json_response(conn, 200)

      conn =
        conn
        |> recycle()
        |> post(~p"/settings/passkeys", %{
          "attestationObject" => b64("bad"),
          "clientDataJSON" => b64("{}"),
          "nickname" => "MacBook"
        })

      assert %{"ok" => false} = json_response(conn, 422)
      assert Credentials.count_for_user(user) == 0
    end
  end

  describe "DELETE /settings/passkeys/:id" do
    test "the owner can remove a passkey", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      credential = insert(:user_credential, user: user)

      conn = delete(recycle(conn), ~p"/settings/passkeys/#{credential.id}")

      assert redirected_to(conn) == ~p"/settings/security"
      assert Credentials.count_for_user(user) == 0
    end

    test "the sign-in & security page lists the owner's passkeys", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      credential = insert(:user_credential, user: user, nickname: "My Laptop")

      html = conn |> get(~p"/settings/security") |> html_response(200)

      assert html =~ "Passkeys"
      assert html =~ "My Laptop"
      assert html =~ ~p"/settings/passkeys/#{credential.id}"
    end
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
