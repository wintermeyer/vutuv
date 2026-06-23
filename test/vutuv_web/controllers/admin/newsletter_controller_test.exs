defmodule VutuvWeb.Admin.NewsletterControllerTest do
  @moduledoc """
  The admin newsletter dashboard: admins-only, composes/stores drafts, sends a
  test, and broadcasts to all members. Email delivers inline in tests, so the
  broadcast runs in-process and the delivery log fills up synchronously.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Newsletters

  defp create_draft(admin) do
    {:ok, newsletter} =
      Newsletters.create_newsletter(
        %{"subject" => "Hello {{first_name}}", "body" => "{{greeting}}, welcome to vutuv."},
        admin
      )

    newsletter
  end

  describe "authorization" do
    test "non-admins are locked out", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert html_response(get(conn, ~p"/admin/newsletters"), 403)
    end
  end

  describe "index" do
    test "lists newsletters and the eligible-member count", %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      create_draft(admin)

      response = html_response(get(conn, ~p"/admin/newsletters"), 200)
      assert response =~ "Newsletters"
      assert response =~ "Hello"
    end
  end

  describe "create" do
    test "saves a draft and redirects to it", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)

      conn =
        post(conn, ~p"/admin/newsletters",
          newsletter: %{"subject" => "My subject", "body" => "Hi {{greeting}}"}
        )

      assert %{id: id} = redirected_params(conn)
      assert redirected_to(conn) == ~p"/admin/newsletters/#{id}"
      assert Newsletters.get_newsletter!(id).subject == "My subject"
    end

    test "re-renders on invalid input", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      conn = post(conn, ~p"/admin/newsletters", newsletter: %{"subject" => "", "body" => ""})
      assert html_response(conn, 200) =~ "New newsletter"
    end
  end

  describe "show" do
    test "renders a preview and the delivery log", %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      newsletter = create_draft(admin)

      response = html_response(get(conn, ~p"/admin/newsletters/#{newsletter}"), 200)
      # The preview substitutes the admin's own data into the variables: the raw
      # subject keeps "{{first_name}}" but the rendered preview shows "Hello admin".
      assert response =~ "Hello admin"
      assert response =~ "welcome to vutuv"
      assert response =~ "Delivery log"
    end

    test "delivery log honors the search query param", %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      newsletter = create_draft(admin)
      {:ok, _} = Newsletters.deliver_test(newsletter, "keep@example.com", admin)
      {:ok, _} = Newsletters.deliver_test(newsletter, "drop@example.com", admin)

      response =
        html_response(get(conn, ~p"/admin/newsletters/#{newsletter}?#{%{"q" => "keep"}}"), 200)

      assert response =~ "keep@example.com"
      refute response =~ "drop@example.com"
    end
  end

  describe "test send" do
    test "sends a test and logs it", %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      newsletter = create_draft(admin)

      conn = post(conn, ~p"/admin/newsletters/#{newsletter}/test", email: "probe@example.com")
      assert redirected_to(conn) == ~p"/admin/newsletters/#{newsletter}"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "probe@example.com"

      assert [delivery] = Newsletters.list_deliveries(newsletter)
      assert delivery.kind == "test"
      assert delivery.email == "probe@example.com"
    end

    test "flashes an error on a bad address", %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      newsletter = create_draft(admin)

      conn = post(conn, ~p"/admin/newsletters/#{newsletter}/test", email: "nope")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "valid email"
      assert Newsletters.list_deliveries(newsletter) == []
    end
  end

  describe "edit guard" do
    test "a sent newsletter cannot be edited", %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      newsletter = create_draft(admin)
      {:ok, :started} = Newsletters.start_broadcast(newsletter)

      conn = get(conn, ~p"/admin/newsletters/#{newsletter}/edit")
      assert redirected_to(conn) == ~p"/admin/newsletters/#{newsletter}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "can no longer be edited"
    end
  end
end
