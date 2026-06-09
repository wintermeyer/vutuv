defmodule VutuvWeb.RegistrationDevMailboxTest do
  # async: false — these flip the global :dev_mailbox application env, like the
  # matching login test in session_controller_test.exs.
  use VutuvWeb.ConnCase, async: false

  @valid_attrs %{
    "emails" => %{"0" => %{"value" => "pin-newcomer@example.com"}},
    "first_name" => "Newcomer"
  }

  # After sign-up the member lands on the PIN confirmation page (rendered by
  # PageController, not SessionController). In dev the PIN is waiting in the
  # Swoosh local mailbox at /sent_emails, so that page should offer the same
  # convenience link the login PIN page does — but only when :dev_mailbox is on
  # (true in config/dev.exs), never in test/prod where the route is absent.
  describe "dev email inbox link on the registration PIN page" do
    test "is hidden by default", %{conn: conn} do
      conn = post(conn, ~p"/new_registration", user: @valid_attrs)

      refute html_response(conn, 200) =~ "/sent_emails"
    end

    test "links to the dev mailbox when enabled", %{conn: conn} do
      Application.put_env(:vutuv, :dev_mailbox, true)
      on_exit(fn -> Application.delete_env(:vutuv, :dev_mailbox) end)

      conn = post(conn, ~p"/new_registration", user: @valid_attrs)

      assert html_response(conn, 200) =~ ~s(href="/sent_emails")
    end
  end
end
