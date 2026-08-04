defmodule VutuvWeb.PinScreenCopyTest do
  @moduledoc """
  The wording of the two PIN-entry screens.

  Copy usually needs no test, but each of these three claims was a real
  misreading of the page rather than a matter of taste (reported 2026-08-04),
  and all three are one careless tidy-up away from coming back:

    * "Enter your PIN" on its own reads as an instruction to *invent* a PIN.
      Somebody who skims the page sees that line and little else.
    * A member who mistyped their address one screen ago cannot see the typo,
      because the page never repeats the address back to them.
    * The registration screen advised logging in with "one of your other
      addresses" — at a point where the member has given exactly one and has no
      account yet. That advice belongs to the login screen alone.
  """
  use VutuvWeb.ConnCase, async: true

  # `registration_attrs/1` (ConnCase) mints a fresh address, name and handle per
  # call and uses this module's own tag set. Hand-built literals would put every
  # run of this file on the same email / username / tag rows, which is the
  # documented 40P01 deadlock between async modules inside one `register_user`
  # transaction — and this file is `async: true`.
  defp registration_params(overrides \\ %{}) do
    Map.merge(registration_attrs("pin"), overrides)
  end

  defp pending_email(params), do: params["emails"]["0"]["value"]

  defp registration_pin_screen(conn, params) do
    conn |> post(~p"/new_registration", user: params) |> html_response(200)
  end

  defp registration_pin_screen(conn) do
    registration_pin_screen(conn, registration_params())
  end

  defp login_pin_screen(conn, email) do
    conn |> post(~p"/login", session: %{"email" => email}) |> html_response(200)
  end

  describe "the PIN field says where the PIN comes from" do
    test "on the registration screen", %{conn: conn} do
      body = registration_pin_screen(conn)

      assert body =~ "Enter the PIN from the email"
      # The bare imperative is what invited the misreading; the placeholder now
      # describes the PIN's shape instead of repeating the heading.
      refute body =~ ">Enter your PIN<"
      assert body =~ "6-digit PIN"
    end

    test "on the login screen", %{conn: conn} do
      user = insert(:activated_user)
      email = insert(:email, user: user).value

      body = login_pin_screen(conn, email)

      assert body =~ "Enter the PIN from the email"
      assert body =~ "6-digit PIN"
    end
  end

  describe "the pending address is named so a typo is visible" do
    test "the registration screen prints the address that was just entered",
         %{conn: conn} do
      params = registration_params()
      body = registration_pin_screen(conn, params)

      assert body =~ pending_email(params)
      # Named, not merely referred to: "that email address" is what a member
      # cannot check their typing against.
      # The whole "no PIN arrived" answer is one paragraph now, so the spam
      # advice must have come with it rather than been dropped.
      assert body =~ "spam folder"
    end

    test "the login screen prints it too", %{conn: conn} do
      user = insert(:activated_user)
      email = insert(:email, user: user).value

      assert login_pin_screen(conn, email) =~ email
    end

    test "the placeholder never reaches the page", %{conn: conn} do
      refute registration_pin_screen(conn) =~ "{email}"
    end
  end

  describe "the other-addresses advice belongs to the login screen only" do
    test "the registration screen does not give it", %{conn: conn} do
      refute registration_pin_screen(conn) =~ "other addresses to your vutuv account"
    end

    test "the login screen still does", %{conn: conn} do
      user = insert(:activated_user)
      email = insert(:email, user: user).value

      assert login_pin_screen(conn, email) =~ "other addresses to your vutuv account"
    end
  end

  describe "coming back to \"/\" while a PIN is in flight" do
    # The gap that let the login-only advice reappear after it had been removed
    # from the registration screen: "/" is pinned to the PIN form while a PIN is
    # pending, and it always rendered the LOGIN screen — whatever flow the
    # visitor was actually in. Checking only the /new_registration response
    # missed it entirely (reported 2026-08-04, with a screenshot of both tabs).
    test "a pending registration shows the registration screen, not the login one",
         %{conn: conn} do
      conn = post(conn, ~p"/new_registration", user: registration_params())

      body = conn |> recycle() |> get(~p"/") |> html_response(200)

      assert body =~ "Enter the PIN from the email"
      refute body =~ "other addresses to your vutuv account"
      assert body =~ "Cancel registration"
    end

    test "a pending login still shows the login screen", %{conn: conn} do
      user = insert(:activated_user)
      email = insert(:email, user: user).value
      conn = post(conn, ~p"/login", session: %{"email" => email})

      body = conn |> recycle() |> get(~p"/") |> html_response(200)

      assert body =~ "other addresses to your vutuv account"
      assert body =~ "Use a different email address"
      refute body =~ "Cancel registration"
    end

    # Both registration branches must leave an identical cookie, or which screen
    # "/" renders would answer "does this address already have an account?" to
    # anyone who types someone else's address.
    test "an already-taken address leaves the same registration screen", %{conn: conn} do
      user = insert(:activated_user)
      taken = insert(:email, user: user).value

      conn =
        post(conn, ~p"/new_registration",
          user: registration_params(%{"emails" => %{"0" => %{"value" => taken}}})
        )

      body = conn |> recycle() |> get(~p"/") |> html_response(200)

      assert body =~ "Enter the PIN from the email"
      refute body =~ "other addresses to your vutuv account"
    end
  end

  describe "the flow survives everything that re-renders a PIN screen" do
    # Found by review, not by use: "Resend PIN" posts to /login/resend from BOTH
    # screens, and re-minting the cookie there used to spell the flow :login by
    # default. One tap therefore turned a pending registration into a pending
    # login for the rest of that PIN's life — on "/" as well, permanently
    # undoing the screen fix above.
    test "resending a PIN keeps a registration a registration", %{conn: conn} do
      conn = post(conn, ~p"/new_registration", user: registration_params())
      conn = submit_with_csrf(conn, ~p"/login/resend", %{})

      body = html_response(conn, 200)
      assert body =~ "Cancel registration"
      refute body =~ "other addresses to your vutuv account"

      # And it is still a registration on the landing page afterwards.
      landing = conn |> recycle() |> get(~p"/") |> html_response(200)
      refute landing =~ "other addresses to your vutuv account"
    end

    # The other three sites that render a PIN screen. A member mid-registration
    # is logged out, so nothing stops them opening /login.
    test "opening /login mid-registration shows the registration screen", %{conn: conn} do
      conn = post(conn, ~p"/new_registration", user: registration_params())

      body = conn |> recycle() |> get(~p"/login") |> html_response(200)

      assert body =~ "Cancel registration"
      refute body =~ "other addresses to your vutuv account"
    end

    test "a plain login through /login is unaffected", %{conn: conn} do
      user = insert(:activated_user)
      email = insert(:email, user: user).value
      conn = post(conn, ~p"/login", session: %{"email" => email})
      conn = submit_with_csrf(conn, ~p"/login/resend", %{})

      body = html_response(conn, 200)
      assert body =~ "other addresses to your vutuv account"
      refute body =~ "Cancel registration"
    end
  end

  describe "a second attempt at an unfinished sign-up" do
    # The dead end this closes: the account is created before the PIN is sent,
    # so registering the same address again hit "email taken" and answered with
    # a "somebody tried to register" notice instead of a PIN. The member sat on
    # a PIN screen waiting for something that was never coming. Reached by a
    # deliberate cancel-and-retry, but far more often by a double-submitted
    # form, a back button or a lost tab.
    test "sends a usable PIN instead of a notice", %{conn: conn} do
      params = registration_params()
      post(conn, ~p"/new_registration", user: params)
      assert_received {:email, first}
      assert first.text_body =~ ~r/\b\d{6}\b/

      # Same address, second go.
      conn = post(build_conn(), ~p"/new_registration", user: params)

      assert html_response(conn, 200) =~ "Enter the PIN from the email"
      assert_received {:email, second}

      assert second.text_body =~ ~r/\b\d{6}\b/,
             "the second attempt must carry a PIN, not a registration notice"
    end

    test "the second PIN actually logs the member in", %{conn: conn} do
      params = registration_params()
      post(conn, ~p"/new_registration", user: params)

      conn = post(build_conn(), ~p"/new_registration", user: params)
      pin = sent_pin()
      conn = submit_with_csrf(conn, ~p"/login", %{"session" => %{"pin" => pin}})

      assert redirected_to(conn) =~ ~r"^/"
      refute redirected_to(conn) == ~p"/login"
    end

    # An established member is untouched: their address must still answer with
    # the notice, never with a PIN somebody else's form submission triggered.
    test "an established member still gets the notice, not a PIN", %{conn: conn} do
      user = insert(:activated_user)
      email = insert(:email, user: user).value

      post(conn, ~p"/new_registration",
        user: registration_params(%{"emails" => %{"0" => %{"value" => email}}})
      )

      assert_received {:email, sent}

      refute sent.text_body =~ ~r/\b\d{6}\b/,
             "an established member must never be mailed a PIN by somebody else's sign-up"
    end
  end

  describe "the way out of the PIN step" do
    test "registration offers to cancel, not to swap the address", %{conn: conn} do
      body = registration_pin_screen(conn)

      assert body =~ "Cancel registration"
      refute body =~ "Use a different email address"
      # Whatever it is called, the escape hatch itself must stay: it is the only
      # thing that frees the landing page while a PIN is pending.
      assert body =~ ~s(action="/login/cancel")
    end

    test "cancelling a registration returns to the sign-up form", %{conn: conn} do
      conn = post(conn, ~p"/new_registration", user: registration_params())
      # submit_with_csrf/3 recycles internally and reads the token out of this
      # response, so it must be handed the POST result, not a recycled conn.
      conn = submit_with_csrf(conn, ~p"/login/cancel", %{})

      # Not /login: somebody who just abandoned signing up has no account to
      # sign in to, so the login form is the one page that cannot help them.
      assert redirected_to(conn) == ~p"/"

      body = conn |> recycle() |> get(~p"/") |> html_response(200)

      assert body =~ ~s(name="user[first_name]")
      refute body =~ "Enter the PIN from the email"
    end

    test "cancelling a login returns to the login form", %{conn: conn} do
      user = insert(:activated_user)
      email = insert(:email, user: user).value
      conn = post(conn, ~p"/login", session: %{"email" => email})
      conn = submit_with_csrf(conn, ~p"/login/cancel", %{})

      assert redirected_to(conn) == ~p"/login"
    end
  end

  test "the German render says all of it in German", %{conn: conn} do
    params = registration_params()

    body =
      conn
      |> put_req_header("accept-language", "de-DE,de;q=0.9")
      |> registration_pin_screen(params)

    assert body =~ "PIN aus der E-Mail eingeben"
    assert body =~ "6-stellige PIN"
    assert body =~ "Kommt keine PIN an?"
    assert body =~ "Spam-Ordner"
    assert body =~ pending_email(params)
    refute body =~ "weitere Adressen hinzugefügt"
  end
end
