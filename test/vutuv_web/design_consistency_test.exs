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

    # The shared `<.page_header>` component replaces the `.profile-header` h1 +
    # `.breadcrumbs` boilerplate that opened ~47 controller pages. It must keep the
    # exact legacy anatomy (`.profile-header > .profile-header__info > h1` and the
    # `.breadcrumbs` row holding `gen_breadcrumbs/1`'s `.breadcrumbs__link`s) so
    # `components.css` keeps styling it and the rendered DOM is unchanged. The
    # email index is a representative converted site: it passes both a `title`
    # (the page h1) and `crumbs` (a list ending at "Emails", with a linked name
    # crumb in the middle).
    test "the email index renders the page_header h1 and breadcrumbs", %{conn: conn, user: user} do
      conn = get(conn, ~p"/users/#{user}/emails")
      html = html_response(conn, 200)

      # The profile-header h1 block carries the page title.
      assert html =~ ~s(<div class="profile-header">)
      assert html =~ ~s(<div class="profile-header__info">)
      assert html =~ "Emails belonging to"

      # The breadcrumbs row holds gen_breadcrumbs output: a linked middle crumb
      # (the user's name) and the trailing leaf label "Emails".
      assert html =~ ~s(<div class="breadcrumbs">)
      assert html =~ ~s(class="breadcrumbs__link" href="#{~p"/users/#{user}"}")
      assert html =~ "/ Emails\n</div>"
    end

    test "the email visibility select is translated", %{conn: conn, user: user} do
      # The select moved off the profile form when email editing was reduced
      # to the public? flag; it now lives only on the email edit page.
      %{emails: [email]} = Repo.preload(user, :emails)

      conn =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de")
        |> get(~p"/users/#{user}/emails/#{email}/edit")

      html = html_response(conn, 200)
      assert html =~ "Öffentlich"
      refute html =~ ~s(>Public<)
    end
  end

  # The search_term/show detail page was the last page still on raw pure.css
  # markup (`.pure-g`/`.pure-u`/`.pure-button`) with hardcoded English labels
  # (`<strong>Value:</strong>`) that bypassed gettext. It is brought onto the
  # standard legacy shell (`<.page_header>` + `<.card_section>` + h1/p detail
  # rows, like email/show) with every label wrapped in gettext. This test pins
  # the new intended markup: it fails on the old page and passes once converted.
  describe "search term detail page" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "uses the standard chrome and card shell, not pure.css", %{conn: conn, user: user} do
      search_term = insert(:search_term, user: user)
      conn = get(conn, ~p"/users/#{user}/search_terms/#{search_term}")
      html = html_response(conn, 200)

      # Standard legacy chrome + card shell instead of the pure.css grid.
      assert html =~ "profile-header"
      assert html =~ "breadcrumbs"
      assert html =~ ~s(class="card)
      refute html =~ "pure-g"
      refute html =~ "pure-u"
      refute html =~ "pure-button"

      # The search term's value still shows.
      assert html =~ search_term.value
    end

    test "wraps its labels in gettext (German renders 'Wert' for 'Value')", %{
      conn: conn,
      user: user
    } do
      search_term = insert(:search_term, user: user)

      conn =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de")
        |> get(~p"/users/#{user}/search_terms/#{search_term}")

      html = html_response(conn, 200)

      # The old page hardcoded "<strong>Value:</strong>"; the converted page
      # routes the label through gettext, so the German locale shows "Wert".
      assert html =~ "Wert"
      refute html =~ ~s(<strong>Value:</strong>)
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

  # The shared `<.card_section>` component replaces the copy-pasted
  # `<div class="card-list"><section class="card">…</section></div>` shell that
  # wrapped every owned-resource index (with its `card__empty` empty-state and an
  # owner-guarded `card__morelink` "Add" link) and ~20 new/edit form wrappers. It
  # must keep the exact legacy classes (`.card-list`, `.card`, `.card__empty`,
  # `.card__morelink`) so `components.css` keeps styling them, the empty line must
  # stay gated on the collection, and the Add link must stay owner-only where the
  # call site guards it. The phone-number index is a representative converted
  # site: it starts empty and guards its Add link with `same_user?/2`.
  describe "shared legacy card section" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "an empty owned index shows the empty line and an owner Add link", %{
      conn: conn,
      user: user
    } do
      conn = get(conn, ~p"/users/#{user}/phone_numbers")
      html = html_response(conn, 200)

      # The legacy card shell and empty-state line.
      assert html =~ ~s(class="card-list")
      assert html =~ ~s(<section class="card">)
      assert html =~ ~s(<p class="card__empty">)
      assert html =~ "Nothing here yet."

      # The owner sees the Add link into the new-route.
      assert html =~ ~s(class="card__morelink")
      assert html =~ ~p"/users/#{user}/phone_numbers/new"
    end

    test "a non-owner sees no Add link on someone else's empty index", %{conn: conn} do
      other = insert(:user, validated?: true)
      insert(:slug, value: other.active_slug, disabled: false, user: other)
      conn = get(conn, ~p"/users/#{other}/phone_numbers")
      html = html_response(conn, 200)

      assert html =~ ~s(<p class="card__empty">)
      refute html =~ ~s(class="card__morelink")
    end

    test "a new page wraps its form in the card section shell", %{conn: conn, user: user} do
      conn = get(conn, ~p"/users/#{user}/phone_numbers/new")
      html = html_response(conn, 200)

      assert html =~ ~s(class="card-list")
      assert html =~ ~s(<section class="card">)
      # The form_content is rendered inside the shell (its submit button is present).
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
