defmodule VutuvWeb.SectionViewAsTest do
  @moduledoc """
  The public/editor split on the profile section pages. The old owner-only
  "View as" switcher is gone from these pages: /:slug/<section> IS the public
  view now, identical for every viewer (the owner included), and all editing
  happens on the user-agnostic /settings/<section> twin. The only owner
  affordance left on the public page is the quiet "Manage ›" header bridge.
  The emails page is the sharp case: private addresses render **only** on
  /settings/emails, never on the public page — not even for the owner.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  describe "work_experiences: public page vs /settings editor" do
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

    test "the owner's public page shows the showcase view plus only the Manage bridge",
         %{conn: conn, owner: owner, job: job} do
      html = conn |> get(~p"/#{owner}/work_experiences") |> html_response(200)

      # No switcher and no banner: there is nothing to preview any more.
      refute html =~ "view-as-switcher"
      refute html =~ "view-as-banner"
      # The one owner affordance: the quiet bridge into the /settings editor.
      assert html =~ ~s(class="profile-header__manage")
      assert html =~ ~s(href="#{~p"/settings/work_experiences"}")
      # No owner chrome on the public page itself.
      refute html =~ ~p"/settings/work_experiences/new"
      refute html =~ ~p"/settings/work_experiences/#{job}/edit"
      # Timeline content: title, organization and the full description all show.
      assert html =~ "Founder"
      assert html =~ "Wintermeyer Consulting"
      assert html =~ "Built the thing"
    end

    test "a stale ?view_as=public URL renders the same public page", %{
      conn: conn,
      owner: owner
    } do
      html =
        conn |> get(~p"/#{owner}/work_experiences?#{[view_as: "public"]}") |> html_response(200)

      refute html =~ "view-as-switcher"
      assert html =~ "Founder"
    end

    test "a visitor sees the same page, minus the Manage bridge", %{owner: owner} do
      html = build_conn() |> get(~p"/#{owner}/work_experiences") |> html_response(200)

      refute html =~ ~s(class="profile-header__manage")
      refute html =~ "/settings/work_experiences"
      assert html =~ "Founder"
      assert html =~ "Built the thing"
    end

    test "the /settings editor carries the owner chrome", %{conn: conn, job: job} do
      html = conn |> get(~p"/settings/work_experiences") |> html_response(200)

      assert html =~ "data-settings-shell"
      assert html =~ ~p"/settings/work_experiences/new"
      assert html =~ ~p"/settings/work_experiences/#{job}/edit"
      assert html =~ "Founder"
    end
  end

  describe "emails: private addresses live only in the /settings editor" do
    setup %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      # The registration email is public; add a private one.
      private = insert(:email, user: owner, value: "geheim@example.com", public?: false)
      %{conn: conn, owner: owner, private: private}
    end

    test "the public page hides private addresses from everyone, the owner included",
         %{conn: conn, owner: owner, private: private} do
      html = conn |> get(~p"/#{owner}/emails") |> html_response(200)
      refute html =~ private.value

      visitor_html = build_conn() |> get(~p"/#{owner}/emails") |> html_response(200)
      refute visitor_html =~ private.value
    end

    test "the /settings editor shows every address, private ones included",
         %{conn: conn, private: private} do
      html = conn |> get(~p"/settings/emails") |> html_response(200)
      assert html =~ private.value
    end

    test "a stale ?view_as=connection URL is just the public page (tiers gone)",
         %{conn: conn, owner: owner, private: private} do
      html =
        conn
        |> get(~p"/#{owner}/emails?#{[view_as: "connection"]}")
        |> html_response(200)

      refute html =~ private.value
      refute html =~ "view-as-switcher"
    end
  end
end
