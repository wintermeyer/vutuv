defmodule VutuvWeb.Admin.NewsletterGroupLiveTest do
  @moduledoc """
  The newsletter audience builder LiveView: admins-only, shows the live matching
  count, and freezes a group on save.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Newsletters

  defp member(value, attrs \\ []) do
    user = insert(:activated_user, attrs)
    insert(:email, user: user, value: value)
    user
  end

  describe "authorization" do
    test "non-admins are locked out", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert html_response(get(conn, ~p"/admin/newsletter_groups"), 403)
    end
  end

  describe "builder" do
    test "shows the live count and saves a fixed group", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      member("d1@x.com", locale: "de")
      member("d2@x.com", locale: "de")
      member("e1@x.com", locale: "en")

      {:ok, lv, html} = live(conn, ~p"/admin/newsletter_groups/new")
      assert html =~ "Members matching"

      # Narrowing the filter re-renders the count without a reload.
      changed =
        lv
        |> form("#group-form", newsletter_group: %{name: "DE folks", locales: ["de"]})
        |> render_change()

      assert changed =~ "Members matching"

      lv
      |> form("#group-form", newsletter_group: %{name: "DE folks", locales: ["de"]})
      |> render_submit()

      assert_redirect(lv, ~p"/admin/newsletter_groups")

      assert [group] = Newsletters.list_groups()
      assert group.name == "DE folks"
      assert group.locales == ["de"]
      assert group.member_count == 2
    end

    test "lists groups on the index and links each to its show page", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      {:ok, group} = Newsletters.create_group(%{"name" => "Everyone"})

      {:ok, lv, _html} = live(conn, ~p"/admin/newsletter_groups")
      assert has_element?(lv, ~s|a[href="/admin/newsletter_groups/#{group.id}"]|, "Everyone")
    end

    test "the builder previews matching members with profile links", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      member("ada@x.com", username: "ada-l")

      {:ok, lv, _html} = live(conn, ~p"/admin/newsletter_groups/new")
      assert has_element?(lv, ~s|#audience-preview a[href="/ada-l"]|)
    end

    test "the username filter narrows the preview live (with wildcards)", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      member("g@x.com", username: "grace-hopper")
      member("a@x.com", username: "ada-lovelace")

      {:ok, lv, _html} = live(conn, ~p"/admin/newsletter_groups/new")

      lv |> form("#group-form", newsletter_group: %{username: "grace*"}) |> render_change()

      assert has_element?(lv, ~s|#audience-preview a[href="/grace-hopper"]|)
      refute has_element?(lv, ~s|#audience-preview a[href="/ada-lovelace"]|)
    end

    test "audiences can be added (union) and subtracted", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      {:ok, _group} = Newsletters.create_group(%{"name" => "Existing"})

      {:ok, lv, _html} = live(conn, ~p"/admin/newsletter_groups/new")
      assert has_element?(lv, ~s|#group_username|)

      assert has_element?(
               lv,
               ~s|input[name="newsletter_group[included_group_ids][]"][type="checkbox"]|
             )

      assert has_element?(
               lv,
               ~s|input[name="newsletter_group[excluded_group_ids][]"][type="checkbox"]|
             )
    end

    test "unticking an account excludes it (Removed chip) and it persists on save", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      ada = member("ada@x.com", username: "ada-l")

      {:ok, lv, _html} = live(conn, ~p"/admin/newsletter_groups/new")
      # ada is in the (unfiltered) audience preview.
      assert has_element?(lv, ~s|#audience-preview a[href="/ada-l"]|)

      # Untick her -> excluded -> leaves the list, shows a Removed chip.
      lv
      |> element(~s|button[phx-click="toggle_member"][phx-value-id="#{ada.id}"]|)
      |> render_click()

      refute has_element?(lv, ~s|#audience-preview a[href="/ada-l"]|)
      assert has_element?(lv, ~s|button[phx-click="restore_member"][phx-value-id="#{ada.id}"]|)

      # Save -> the exclusion is persisted on the group.
      lv |> form("#group-form", newsletter_group: %{name: "No Ada"}) |> render_submit()
      assert [group] = Newsletters.list_groups()
      assert ada.id in group.excluded_user_ids
    end

    test "select all / unselect all toggle the whole audience", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      member("a@x.com")
      member("b@x.com")

      {:ok, lv, _html} = live(conn, ~p"/admin/newsletter_groups/new")
      refute has_element?(lv, "#match-count", "0")

      lv |> element(~s|button[phx-click="unselect_all"]|) |> render_click()
      assert has_element?(lv, "#match-count", "0")

      lv |> element(~s|button[phx-click="select_all"]|) |> render_click()
      refute has_element?(lv, "#match-count", "0")

      # Saving after select-all leaves no manual exclusions behind.
      lv |> form("#group-form", newsletter_group: %{name: "All back"}) |> render_submit()
      assert [group] = Newsletters.list_groups()
      assert group.excluded_user_ids == []
    end

    test "the show page lists a group's members with profile links", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      member("grace@x.com", username: "grace-h")
      {:ok, group} = Newsletters.create_group(%{"name" => "Everyone"})

      {:ok, lv, _html} = live(conn, ~p"/admin/newsletter_groups/#{group.id}")
      assert has_element?(lv, ~s|a[href="/grace-h"]|)
      assert has_element?(lv, "h1", "Everyone")
    end

    test "a valid filter change shows no validation error", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)

      {:ok, lv, _html} = live(conn, ~p"/admin/newsletter_groups/new")

      lv
      |> form("#group-form", newsletter_group: %{name: "Germans", locales: ["de"]})
      |> render_change()

      refute has_element?(lv, ".alert-danger")
    end

    test "an actually invalid change shows the validation error", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)

      {:ok, lv, _html} = live(conn, ~p"/admin/newsletter_groups/new")

      # Clearing the required name makes the changeset invalid.
      lv
      |> form("#group-form", newsletter_group: %{name: "", locales: ["de"]})
      |> render_change()

      assert has_element?(lv, ".alert-danger")
    end

    test "the new form prefills a timestamped name and offers the random toggle", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)

      {:ok, lv, _html} = live(conn, ~p"/admin/newsletter_groups/new")
      assert has_element?(lv, "#group_random")

      # Submitting with the defaults keeps the prefilled, timestamped name.
      lv |> form("#group-form") |> render_submit()

      assert [group] = Newsletters.list_groups()
      assert group.name =~ ~r/^Audience \d{4}-\d{2}-\d{2} \d{2}:\d{2}$/
    end
  end

  describe "specific-accounts mode (hand-picked allowlist)" do
    test "switching to Specific accounts hides the filters and shows the picker", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)

      {:ok, lv, _html} = live(conn, ~p"/admin/newsletter_groups/new")
      # The default builder shows the filter inputs.
      assert has_element?(lv, "#group_username")

      lv |> element("#mode-accounts") |> render_click()

      assert has_element?(lv, "#account_search")
      assert has_element?(lv, "#chosen-accounts")
      refute has_element?(lv, "#group_username")
    end

    test "search, add an account, and save a group of exactly that account", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      grace = member("g@x.com", username: "grace-hopper")
      _ada = member("a@x.com", username: "ada-lovelace")

      {:ok, lv, _html} = live(conn, ~p"/admin/newsletter_groups/new")
      lv |> element("#mode-accounts") |> render_click()

      # Find grace and add her to the allowlist.
      lv |> form("#group-form", %{member_search: "grace*"}) |> render_change()
      assert has_element?(lv, ~s|button[phx-click="add_member"][phx-value-id="#{grace.id}"]|)

      lv
      |> element(~s|button[phx-click="add_member"][phx-value-id="#{grace.id}"]|)
      |> render_click()

      assert has_element?(lv, "#account-count", "1")

      lv |> form("#group-form", newsletter_group: %{name: "Beta testers"}) |> render_submit()
      assert_redirect(lv, ~p"/admin/newsletter_groups")

      assert [group] = Newsletters.list_groups()
      assert group.name == "Beta testers"
      assert group.included_user_ids == [grace.id]
      assert group.locales == []
      assert group.member_count == 1
    end

    test "an allowlist group reopens in Specific accounts mode on edit", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      picked = member("p@x.com", username: "picked-one")

      {:ok, group} =
        Newsletters.create_group(%{"name" => "Testers", "included_user_ids" => [picked.id]})

      {:ok, lv, _html} = live(conn, ~p"/admin/newsletter_groups/#{group.id}/edit")

      assert has_element?(lv, "#account_search")
      assert has_element?(lv, ~s|#chosen-accounts a[href="/picked-one"]|)
      refute has_element?(lv, "#group_username")
    end
  end
end
