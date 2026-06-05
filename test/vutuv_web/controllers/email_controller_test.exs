defmodule VutuvWeb.EmailControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Accounts.Email

  # The address itself is an identity: adding one is PIN-verified
  # (EmailController.create/confirm, issue #759). Editing must therefore be
  # limited to the public? flag — changing the value would attach an address
  # the user never proved to own.

  describe "edit" do
    test "shows the address read-only, without a value input", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{emails: [email]} = Repo.preload(user, :emails)

      conn = get(conn, ~p"/users/#{user}/emails/#{email}/edit")
      html = html_response(conn, 200)

      assert html =~ email.value
      refute html =~ "email[value]"
    end
  end

  describe "update" do
    test "toggles public? but never changes the address itself", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{emails: [email]} = Repo.preload(user, :emails)
      assert email.public?

      conn =
        put(conn, ~p"/users/#{user}/emails/#{email}",
          email: %{"value" => "hijacked@example.com", "public?" => "false"}
        )

      assert redirected_to(conn) == ~p"/users/#{user}/emails/#{email}"
      reloaded = Repo.get(Email, email.id)
      assert reloaded.value == email.value
      refute reloaded.public?
    end
  end
end
