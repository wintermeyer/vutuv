defmodule VutuvWeb.DesignConsistencyTest do
  @moduledoc """
  Guards the "Direction A" design language across the pages that historically
  escaped it: pages must render the standard chrome (`.profile-header` title,
  `.breadcrumbs`, `.card` surface) instead of bare pure.css markup, error pages
  must be styled and helpful, and the German locale must reach LiveView pages
  (the chrome used to flip back to English on /messages and /notifications).
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "page chrome consistency" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "groups index uses the standard page chrome", %{conn: conn, user: user} do
      insert(:group, user: user)
      conn = get(conn, ~p"/users/#{user}/groups")
      html = html_response(conn, 200)

      assert html =~ "profile-header"
      assert html =~ "breadcrumbs"
      assert html =~ ~s(class="card)
      refute html =~ "pure-button"
    end

    test "search terms index uses the standard page chrome", %{conn: conn, user: user} do
      conn = get(conn, ~p"/users/#{user}/search_terms")
      html = html_response(conn, 200)

      assert html =~ "profile-header"
      assert html =~ "breadcrumbs"
      assert html =~ ~s(class="card)
      refute html =~ "pure-button"
    end

    test "the email visibility select is translated", %{conn: conn, user: user} do
      conn =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de")
        |> get(~p"/users/#{user}/edit")

      html = html_response(conn, 200)
      assert html =~ "Öffentlich"
      refute html =~ ~s(>Public<)
    end
  end

  describe "admin dashboard" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      insert(:user, last_name: nil)
      %{conn: conn, admin: admin}
    end

    test "uses the standard chrome and a non-destructive verify button", %{conn: conn} do
      conn = get(conn, ~p"/admin")
      html = html_response(conn, 200)

      assert html =~ "profile-header"
      assert html =~ ~s(class="card)
      # Verifying a user is a positive action, not a destructive one.
      refute html =~ "button--danger"
    end
  end

  describe "error pages" do
    test "the 404 page is styled and links back home", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # The slugs feature is intentionally disabled via Plug.All404.
      conn = get(conn, ~p"/users/#{user}/slugs")
      html = html_response(conn, 404)

      assert html =~ "error-page"
      assert html =~ ~s(href="/")
    end
  end

  describe "locale on LiveView pages" do
    test "a German visitor keeps the German chrome on /notifications", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, view, _html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de")
        |> live(~p"/notifications")

      assert render(view) =~ "Benachrichtigungen"
    end
  end

  # The shared `<.form_error>` / `<.form_actions>` components replace markup that
  # was copy-pasted into ~20 legacy form_content templates. They must keep the
  # exact legacy classes (`.alert`, `.editform__error`, `.editform__actions`,
  # `.button`, `.button--cancel`) so `components.css` keeps styling them, and the
  # banner must stay conditional on `@changeset.action`. The phone-number form is
  # a representative converted site: its controller re-renders the form with a
  # failed changeset on invalid input.
  describe "shared legacy form components" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "a fresh form hides the error banner but shows Cancel + Submit", %{
      conn: conn,
      user: user
    } do
      conn = get(conn, ~p"/users/#{user}/phone_numbers/new")
      html = html_response(conn, 200)

      refute html =~ "alert-danger"
      refute html =~ "Oops, something went wrong"

      # The Cancel link points back to the @backlink the controller passes.
      assert html =~ ~s(class="button button--cancel" href="#{~p"/users/#{user}/phone_numbers"}")
      assert html =~ ~s(<button class="button" type="submit">)
    end

    test "a failed submit re-renders the form with the error banner", %{conn: conn, user: user} do
      conn = post(conn, ~p"/users/#{user}/phone_numbers", phone_number: %{"value" => ""})
      html = html_response(conn, 200)

      assert html =~ ~s(class="alert alert-danger")
      assert html =~ ~s(<p class="editform__error">)
      assert html =~ "Oops, something went wrong"

      # The actions row still renders on the failed re-render.
      assert html =~ ~s(class="button button--cancel")
      assert html =~ ~s(<button class="button" type="submit">)
    end
  end

  # The shared `<.edit_delete_actions>` component replaces ~16 hand-written
  # edit/delete icon-button pairs that had drifted into two icon flavors and two
  # button orders. It renders the canonical legacy anatomy from design.md: a
  # `.btns-right` wrapper holding `.button.button--icon.button--small` controls
  # with CSS-glyph icons (`i.icon.icon--edit|--delete|--search`), edit before
  # delete, delete rendered through the `delete` method so CSRF applies. The
  # email card_list (owner view) and the address show page are representative
  # converted sites; the address show test is also the regression for the bug
  # where its delete button defaulted to POST (no POST route exists), so the
  # control silently failed to delete.
  describe "shared edit/delete icon-button actions" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "the email card_list renders the canonical edit-then-delete glyph group",
         %{conn: conn, user: user} do
      [email | _] = user.emails
      conn = get(conn, ~p"/users/#{user}/emails")
      html = html_response(conn, 200)

      # Canonical wrapper and CSS-glyph icons (not the IconHTML svg flavor).
      assert html =~ ~s(class="btns-right")
      assert html =~ ~s(<i class="icon icon--edit"></i>)
      assert html =~ ~s(<i class="icon icon--delete"></i>)

      # The edit link points at the edit route.
      assert html =~ ~s(href="#{~p"/users/#{user}/emails/#{email}/edit"}")

      # The delete control carries the delete method + danger class and renders
      # before nothing else (edit comes first in the source order).
      assert html =~ ~s(data-method="delete")
      assert html =~ "button--danger"

      edit_pos = :binary.match(html, ~s(icon--edit)) |> elem(0)
      delete_pos = :binary.match(html, ~s(icon--delete)) |> elem(0)
      assert edit_pos < delete_pos, "edit icon must come before delete icon"
    end

    test "the address show page deletes via the delete method, not POST",
         %{conn: conn, user: user} do
      address = insert(:address, user: user)
      conn = get(conn, ~p"/users/#{user}/addresses/#{address}")
      html = html_response(conn, 200)

      # Regression: the old delete button had no `method`, so it defaulted to
      # POST against a path that has no POST route. The component always emits
      # the delete method.
      assert html =~ ~s(data-method="delete")
      assert html =~ ~s(data-to="#{~p"/users/#{user}/addresses/#{address}"}")
      assert html =~ "button--danger"

      # Edit link and canonical glyph icons are present.
      assert html =~ ~s(href="#{~p"/users/#{user}/addresses/#{address}/edit"}")
      assert html =~ ~s(<i class="icon icon--edit"></i>)
      assert html =~ ~s(<i class="icon icon--delete"></i>)
    end
  end
end
