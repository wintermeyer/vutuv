defmodule VutuvWeb.SectionViewAsTest do
  @moduledoc """
  The owner-only "View as" preview switcher on the profile section index pages
  (VutuvWeb.ViewAs + the shared <.view_as_switcher>), and the work_experiences
  timeline restyle. Most sections are fully public, so the switcher there only
  toggles the owner's Add / Edit / Delete chrome; the emails page additionally
  hides private addresses in the visitor preview modes.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  describe "work_experiences index: timeline + view-as switcher" do
    setup %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)

      job =
        insert(:work_experience,
          user: owner,
          title: "Founder",
          organization: "Wintermeyer Consulting",
          description: "Built the thing",
          start_month: 1,
          start_year: 2017
        )

      %{conn: conn, owner: owner, job: job}
    end

    test "owner's own view: switcher (no banner), add tile, inline edit/delete, timeline content",
         %{conn: conn, owner: owner, job: job} do
      html = conn |> get(~p"/#{owner}/work_experiences") |> html_response(200)

      assert html =~ "view-as-switcher"
      refute html =~ "view-as-banner"
      # The switcher is rendered once from the app layout, so its segments must
      # target *this* page (base_path = conn.request_path), not some other
      # section. Guards the layout-level rendering against a wrong base path.
      # Only You / Public remain (Vernetzt was dropped), so there is no
      # connection segment any more.
      assert html =~ ~p"/#{owner}/work_experiences?#{[view_as: "public"]}"
      refute html =~ ~p"/#{owner}/work_experiences?#{[view_as: "connection"]}"
      # Section content is the narrower 48rem column, so the bar matches it
      # (max-w-3xl); only the full-width profile grid gets max-w-6xl.
      assert html =~ "mt-6 max-w-3xl"
      # Owner chrome: the add tile and the inline edit/delete controls.
      assert html =~ ~p"/#{owner}/work_experiences/new"
      assert html =~ ~p"/#{owner}/work_experiences/#{job}/edit"
      # Timeline content: title, organization and the full description all show.
      assert html =~ "Founder"
      assert html =~ "Wintermeyer Consulting"
      assert html =~ "Built the thing"
    end

    test "previewing as public keeps the entries but drops every owner control",
         %{conn: conn, owner: owner, job: job} do
      html =
        conn |> get(~p"/#{owner}/work_experiences?#{[view_as: "public"]}") |> html_response(200)

      assert html =~ "view-as-banner"
      # The role still renders for the previewed visitor...
      assert html =~ "Founder"
      assert html =~ "Built the thing"
      # ...but the add tile and the per-row edit/delete are gone.
      refute html =~ ~p"/#{owner}/work_experiences/new"
      refute html =~ ~p"/#{owner}/work_experiences/#{job}/edit"
    end

    test "a logged-in visitor sees the timeline but no switcher and no owner chrome",
         %{conn: conn} do
      # `conn` (from setup) is logged in as the owner; view a different member.
      profile = insert_activated_user()
      job = insert(:work_experience, user: profile, title: "Engineer", organization: "Span AG")

      html = conn |> get(~p"/#{profile}/work_experiences") |> html_response(200)

      assert html =~ "Engineer"
      refute html =~ "view-as-switcher"
      refute html =~ ~p"/#{profile}/work_experiences/new"
      refute html =~ ~p"/#{profile}/work_experiences/#{job}/edit"
    end
  end

  describe "emails index: view-as filters private addresses" do
    setup %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      insert(:email, user: owner, value: "shown@example.com", public?: true)
      insert(:email, user: owner, value: "secret@example.com", public?: false)
      %{conn: conn, owner: owner}
    end

    test "owner sees private addresses in their own view", %{conn: conn, owner: owner} do
      html = conn |> get(~p"/#{owner}/emails") |> html_response(200)
      assert html =~ "shown@example.com"
      assert html =~ "secret@example.com"
    end

    test "previewing as public hides private addresses", %{conn: conn, owner: owner} do
      html = conn |> get(~p"/#{owner}/emails?#{[view_as: "public"]}") |> html_response(200)
      assert html =~ "view-as-banner"
      assert html =~ "shown@example.com"
      refute html =~ "secret@example.com"
    end

    test "a stale ?view_as=connection falls back to the owner's own view (Vernetzt tier gone)",
         %{conn: conn, owner: owner} do
      # The Vernetzt tier was removed, so "connection" is an unknown view_as
      # value: it resolves to nil, the owner's own view (no banner, private
      # address shown), rather than a visitor preview.
      html = conn |> get(~p"/#{owner}/emails?#{[view_as: "connection"]}") |> html_response(200)
      refute html =~ "view-as-banner"
      assert html =~ "shown@example.com"
      assert html =~ "secret@example.com"
    end
  end

  test "a stranger's ?view_as= is ignored: no switcher, no preview", %{conn: conn} do
    {conn, _visitor} = create_and_login_user(conn)
    owner = insert_activated_user()
    insert(:phone_number, user: owner)

    html =
      conn |> get(~p"/#{owner}/phone_numbers?#{[view_as: "public"]}") |> html_response(200)

    refute html =~ "view-as-switcher"
    refute html =~ "view-as-banner"
  end

  test "the switcher rides along on the other section pages too (phone_numbers)",
       %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    insert(:phone_number, user: owner)

    html = conn |> get(~p"/#{owner}/phone_numbers") |> html_response(200)
    assert html =~ "view-as-switcher"
  end
end
