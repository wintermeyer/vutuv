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

  defp registration_pin_screen(conn) do
    conn
    |> post(~p"/new_registration",
      user: %{
        "first_name" => "Pina",
        "last_name" => "Probe",
        "tag_list" => "Anredetest, Elixir, Kochen",
        "emails" => %{"0" => %{"value" => @email}}
      }
    )
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
