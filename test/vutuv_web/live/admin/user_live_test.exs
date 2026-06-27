defmodule VutuvWeb.Admin.UserLiveTest do
  @moduledoc """
  The admin member browser LiveView (`/admin/users`): admins-only, with live
  search/filter/sort and an inline identity-verify that updates the row without
  a reload.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Accounts.User

  defp pos(body, needle) do
    {at, _} = :binary.match(body, needle)
    at
  end

  describe "authorization" do
    test "non-admins are locked out", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert html_response(get(conn, ~p"/admin/users"), 403)
    end
  end

  describe "browsing" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "the default view shows PIN-registered members and hides unconfirmed ones", %{conn: conn} do
      insert(:activated_user, username: "pinnedmember")
      insert(:user, username: "legacyimport")

      {:ok, _lv, html} = live(conn, ~p"/admin/users")

      assert html =~ "pinnedmember"
      refute html =~ "legacyimport"
    end

    test "members are listed newest first by default", %{conn: conn} do
      older = insert(:activated_user, username: "olderone")
      insert(:activated_user, username: "newerone")

      Repo.update_all(
        from(u in User, where: u.id == ^older.id),
        set: [inserted_at: ~N[2020-01-01 12:00:00]]
      )

      {:ok, _lv, html} = live(conn, ~p"/admin/users")
      assert pos(html, "newerone") < pos(html, "olderone")
    end

    test "search-as-you-type filters the list live", %{conn: conn} do
      insert(:activated_user, first_name: "Zaphod", last_name: "Beeblebrox", username: "zaphod")
      insert(:activated_user, first_name: "Arthur", last_name: "Dent", username: "arthurdent")

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html = lv |> form("#member-filter", %{q: "Beeblebrox"}) |> render_change()

      assert html =~ "zaphod"
      refute html =~ "arthurdent"
    end

    test "search matches usernames with a leading @", %{conn: conn} do
      insert(:activated_user, username: "trillian")

      {:ok, lv, _html} = live(conn, ~p"/admin/users")
      html = lv |> form("#member-filter", %{q: "@trillian"}) |> render_change()

      assert html =~ "trillian"
    end

    test "search finds an account by its email address", %{conn: conn} do
      user = insert(:activated_user, username: "needle", first_name: "Find", last_name: "Me")
      insert(:email, user: user, value: "secret-support@example.com")
      insert(:activated_user, username: "haystack")

      {:ok, lv, _html} = live(conn, ~p"/admin/users")
      html = lv |> form("#member-filter", %{q: "secret-support@example.com"}) |> render_change()

      # The account is found by its email; the row links by @handle (the listing
      # has no email column, so the address itself is never rendered as data).
      assert has_element?(lv, "#user-#{user.id}")
      assert html =~ "needle"
      refute html =~ "haystack"
    end

    test "widening the registration filter reveals unconfirmed members", %{conn: conn} do
      insert(:user, username: "legacyimport")

      {:ok, lv, html} = live(conn, ~p"/admin/users")
      refute html =~ "legacyimport"

      html = lv |> form("#member-filter", %{reg: "all"}) |> render_change()
      assert html =~ "legacyimport"
    end

    test "clicking a column header re-sorts live", %{conn: conn} do
      insert(:activated_user, last_name: "Aaronson", username: "aaamember")
      insert(:activated_user, last_name: "Zimmerman", username: "zzzmember")

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html = lv |> element(~s|button[phx-value-col="name"]|) |> render_click()
      assert pos(html, "aaamember") < pos(html, "zzzmember")
    end

    test "clearing filters returns to the default view", %{conn: conn} do
      insert(:user, username: "legacyimport")

      {:ok, lv, _html} = live(conn, ~p"/admin/users")
      lv |> form("#member-filter", %{reg: "all"}) |> render_change()
      assert render(lv) =~ "legacyimport"

      html = lv |> element("#clear-filters") |> render_click()
      refute html =~ "legacyimport"
    end
  end

  describe "identity verification" do
    setup %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      %{conn: conn}
    end

    test "the unverified filter shows the queue with a verify button", %{conn: conn} do
      unverified = insert(:activated_user, username: "needsverify", identity_verified?: false)
      insert(:activated_user, username: "alreadyverified", identity_verified?: true)

      {:ok, lv, _html} = live(conn, ~p"/admin/users?flag=unverified")

      assert has_element?(lv, ~s|button[phx-click="verify"][phx-value-id="#{unverified.id}"]|)
      assert render(lv) =~ "needsverify"
      refute render(lv) =~ "alreadyverified"
    end

    test "clicking verify flips the row in place and persists, no reload", %{conn: conn} do
      user = insert(:activated_user, username: "needsverify", identity_verified?: false)
      insert(:email, user: user, value: "needs@example.com")

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      assert has_element?(lv, ~s|button[phx-value-id="#{user.id}"]|)

      html =
        lv |> element(~s|button[phx-click="verify"][phx-value-id="#{user.id}"]|) |> render_click()

      # The row is still shown (no reload) but the Verify button is gone and the
      # Verified badge appears.
      assert has_element?(lv, "#user-#{user.id}")
      refute has_element?(lv, ~s|button[phx-value-id="#{user.id}"]|)
      assert html =~ "Verified"

      assert Repo.get!(User, user.id).identity_verified?
    end
  end

  describe "pagination" do
    test "pages through when there are more than one page of members", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      # 51 activated members (+ the admin) overflow the 50/page browser.
      for i <- 1..51, do: insert(:activated_user, username: "member-#{i}")

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      assert has_element?(lv, "#next-page:not([disabled])")
      assert render(lv) =~ "Page 1 of"

      html = lv |> element("#next-page") |> render_click()
      assert html =~ "Page 2 of"
    end
  end
end
