defmodule VutuvWeb.Admin.NewsletterBroadcastLiveTest do
  @moduledoc """
  The newsletter send flow LiveView: pick an audience, confirm in a modal that
  states the recipient count, then watch the live progress view. Email delivers
  inline in tests (`:async_email` is false), so a broadcast runs in-process and
  the newsletter lands on "sent" synchronously.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Newsletters

  defp member(value, attrs \\ []) do
    user = insert(:activated_user, attrs)
    insert(:email, user: user, value: value)
    user
  end

  defp create_draft(admin) do
    {:ok, newsletter} =
      Newsletters.create_newsletter(
        %{"subject" => "Hello {{first_name}}", "body" => "{{greeting}}, welcome."},
        admin
      )

    newsletter
  end

  describe "authorization" do
    test "non-admins are locked out", %{conn: conn} do
      {conn, admin} = create_and_login_user(conn)
      newsletter = create_draft(admin)
      assert html_response(get(conn, ~p"/admin/newsletters/#{newsletter}/send"), 403)
    end
  end

  describe "send flow" do
    test "shows the reach, confirms the count, and broadcasts", %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      member("ann@example.com")
      newsletter = create_draft(admin)

      {:ok, lv, html} = live(conn, ~p"/admin/newsletters/#{newsletter}/send")
      assert html =~ "Send newsletter"
      # The admin plus the inserted member are both eligible.
      assert has_element?(lv, "#reach-count")

      # Opening the confirm modal states how many people it reaches.
      lv |> element("#open-confirm") |> render_click()
      assert has_element?(lv, "#confirm-modal")
      assert render(lv) =~ "Are you sure?"

      # Confirming sends; inline delivery lands the newsletter on "sent".
      lv |> element("#confirm-send") |> render_click()

      refute has_element?(lv, "#confirm-modal")
      assert render(lv) =~ "Done"

      newsletter = Newsletters.get_newsletter!(newsletter.id)
      assert newsletter.status == "sent"
      assert newsletter.recipient_count >= 1

      emails = Enum.map(Newsletters.list_deliveries(newsletter), & &1.email)
      assert "ann@example.com" in emails
    end

    test "a chosen audience only reaches that group", %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      member("de@example.com", locale: "de")
      member("en@example.com", locale: "en")

      {:ok, group} = Newsletters.create_group(%{"name" => "German", "locales" => ["de"]})
      newsletter = create_draft(admin)

      {:ok, lv, _html} = live(conn, ~p"/admin/newsletters/#{newsletter}/send")

      lv
      |> form("#audience-form", %{"group_id" => group.id})
      |> render_change()

      lv |> element("#open-confirm") |> render_click()
      lv |> element("#confirm-send") |> render_click()

      newsletter = Newsletters.get_newsletter!(newsletter.id)
      assert newsletter.group_id == group.id

      emails = Enum.map(Newsletters.list_deliveries(newsletter), & &1.email)
      assert "de@example.com" in emails
      refute "en@example.com" in emails
    end

    test "an already-sent newsletter shows the done view", %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      newsletter = create_draft(admin)
      {:ok, :started} = Newsletters.start_broadcast(newsletter)

      {:ok, _lv, html} = live(conn, ~p"/admin/newsletters/#{newsletter}/send")
      assert html =~ "Done"
    end

    test "a missing newsletter redirects to the index", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      id = Vutuv.UUIDv7.generate()

      assert {:error, {:live_redirect, %{to: "/admin/newsletters"}}} =
               live(conn, ~p"/admin/newsletters/#{id}/send")
    end
  end
end
