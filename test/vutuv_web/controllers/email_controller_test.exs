defmodule VutuvWeb.EmailControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Accounts.Email

  # The address itself is an identity: adding one is PIN-verified
  # (EmailController.create/confirm, issue #759). Editing must therefore be
  # limited to the public? flag — changing the value would attach an address
  # the user never proved to own.

  describe "create" do
    test "the chosen Work/Personal/Other type rides through PIN confirmation", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/settings/emails",
          email: %{"value" => "work@example.com", "email_type" => "Work"}
        )

      assert html_response(conn, 200) =~ "_csrf_token"
      pin = sent_pin()

      conn =
        submit_with_csrf(
          conn,
          ~p"/settings/emails/confirmation",
          %{"email_confirmation" => %{"pin" => pin}}
        )

      assert redirected_to(conn) == ~p"/"
      assert Repo.get_by(Email, value: "work@example.com").email_type == "Work"
    end

    test "rejects a malformed address before mailing a PIN", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      # Drain the login PIN (and any stragglers) so the refute below is precise.
      flush_emails()

      conn =
        post(conn, ~p"/settings/emails", email: %{"value" => "foo@bar", "email_type" => "Other"})

      # Re-renders the new form with the format error instead of advancing to
      # the PIN step...
      assert html_response(conn, 200) =~ "valid email"
      # ...and crucially never mails a PIN to the bogus address.
      refute_received {:email, _}
    end
  end

  describe "edit" do
    test "shows the address read-only, without a value input", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{emails: [email]} = Repo.preload(user, :emails)

      conn = get(conn, ~p"/settings/emails/#{email}/edit")
      html = html_response(conn, 200)

      assert html =~ email.value
      refute html =~ "email[value]"
    end
  end

  describe "update" do
    test "toggles public? but never changes the address itself", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{emails: [email]} = Repo.preload(user, :emails)
      # Privacy by default: a registration without the opt-in box stays private.
      refute email.public?

      conn =
        put(conn, ~p"/settings/emails/#{email}",
          email: %{"value" => "hijacked@example.com", "public?" => "true"}
        )

      assert redirected_to(conn) == ~p"/settings/emails"
      reloaded = Repo.get(Email, email.id)
      assert reloaded.value == email.value
      assert reloaded.public?
    end

    test "re-labels the Work/Personal/Other type", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{emails: [email]} = Repo.preload(user, :emails)
      # The registration backfill default until the owner picks one.
      assert email.email_type == "Other"

      conn = put(conn, ~p"/settings/emails/#{email}", email: %{"email_type" => "Personal"})

      assert redirected_to(conn) == ~p"/settings/emails"
      assert Repo.get(Email, email.id).email_type == "Personal"
    end
  end
end
