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

  @email "tippfehler@example.com"

  defp registration_params(overrides \\ %{}) do
    Map.merge(
      %{
        "first_name" => "Pina",
        "last_name" => "Probe",
        "tag_list" => "Anredetest, Elixir, Kochen",
        "emails" => %{"0" => %{"value" => @email}}
      },
      overrides
    )
  end

  defp registration_pin_screen(conn) do
    conn
    |> post(~p"/new_registration", user: registration_params())
    |> html_response(200)
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
      body = registration_pin_screen(conn)

      assert body =~ @email
      # Named, not merely referred to: "that email address" is what a member
      # cannot check their typing against.
      refute body =~ "That email address may"
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

  describe "the way out of the PIN step" do
    test "registration offers to cancel, not to swap the address", %{conn: conn} do
      body = registration_pin_screen(conn)

      assert body =~ "Cancel registration"
      refute body =~ "Use a different email address"
      # Whatever it is called, the escape hatch itself must stay: it is the only
      # thing that frees the landing page while a PIN is pending.
      assert body =~ ~s(action="/login/cancel")
    end

    test "cancelling frees the landing page again", %{conn: conn} do
      conn = post(conn, ~p"/new_registration", user: registration_params())
      # submit_with_csrf/3 recycles internally and reads the token out of this
      # response, so it must be handed the POST result, not a recycled conn.
      conn = submit_with_csrf(conn, ~p"/login/cancel", %{})

      body = conn |> recycle() |> get(~p"/") |> html_response(200)

      assert body =~ ~s(name="user[first_name]")
      refute body =~ "Enter the PIN from the email"
    end
  end

  test "the German render says all of it in German", %{conn: conn} do
    body =
      conn
      |> put_req_header("accept-language", "de-DE,de;q=0.9")
      |> registration_pin_screen()

    assert body =~ "PIN aus der E-Mail eingeben"
    assert body =~ "6-stelliger PIN"
    assert body =~ "funktioniert möglicherweise gerade nicht"
    assert body =~ @email
    refute body =~ "weitere Adressen hinzugefügt"
  end
end
