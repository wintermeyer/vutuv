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
      conn = get(conn, ~p"/#{user}/groups")
      html = html_response(conn, 200)

      assert html =~ "profile-header"
      assert html =~ "breadcrumbs"
      assert html =~ ~s(class="card)
      refute html =~ "pure-button"
    end

    test "search terms index uses the standard page chrome", %{conn: conn, user: user} do
      conn = get(conn, ~p"/#{user}/search_terms")
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
      conn = get(conn, ~p"/#{user}/emails")
      html = html_response(conn, 200)

      # The profile-header h1 block carries the page title.
      assert html =~ ~s(<div class="profile-header">)
      assert html =~ ~s(<div class="profile-header__info">)
      assert html =~ "Emails belonging to"

      # The breadcrumbs row holds gen_breadcrumbs output: a linked middle crumb
      # (the user's name) and the trailing leaf label "Emails".
      assert html =~ ~s(<div class="breadcrumbs">)
      assert html =~ ~s(class="breadcrumbs__link" href="#{~p"/#{user}"}")
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
        |> get(~p"/#{user}/emails/#{email}/edit")

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
      conn = get(conn, ~p"/#{user}/search_terms/#{search_term}")
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
        |> get(~p"/#{user}/search_terms/#{search_term}")

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
      {conn, _user} = create_and_login_user(conn)
      conn = get(conn, "/this_user_does_not_exist")
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

      # "Mitteilungen" is the one German term for notifications (page title
      # and shell tab agree; "Benachrichtigungen" was retired to stop the
      # three-way Nachrichten/Mitteilungen/Benachrichtigungen mix).
      assert render(view) =~ "Mitteilungen"
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
      conn = get(conn, ~p"/#{user}/phone_numbers/new")
      html = html_response(conn, 200)

      refute html =~ "alert-danger"
      refute html =~ "Oops, something went wrong"

      # The Cancel link points back to the @backlink the controller passes.
      assert html =~ ~s(class="button button--cancel" href="#{~p"/#{user}/phone_numbers"}")
      assert html =~ ~s(<button class="button" type="submit">)
    end

    test "a failed submit re-renders the form with the error banner", %{conn: conn, user: user} do
      conn = post(conn, ~p"/#{user}/phone_numbers", phone_number: %{"value" => ""})
      html = html_response(conn, 200)

      assert html =~ ~s(class="alert alert-danger")
      assert html =~ ~s(<p class="editform__error">)
      assert html =~ "Oops, something went wrong"

      # The actions row still renders on the failed re-render.
      assert html =~ ~s(class="button button--cancel")
      assert html =~ ~s(<button class="button" type="submit">)
    end
  end

  # The shared `<.card_section>` component still wraps every owned-resource index
  # in the legacy `.card-list`/`.card` shell (so `components.css` keeps styling
  # it). Under the unified card UX its "Add" now follows the profile: an EMPTY
  # owner card shows the prominent dashed `<.empty_add>` tile (data-empty-add)
  # into the new-route instead of the old `card__empty` + bottom `card__morelink`
  # (a populated card shows the visible `<.add_action>` header button instead). A
  # visitor on someone else's empty index has no add affordance, so it falls back
  # to the plain `.card__empty` line. The phone-number index is a representative
  # converted site: it starts empty and guards its add affordance with `same_user?/2`.
  describe "shared legacy card section" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "an empty owned index shows the owner a dashed add tile into the new-route", %{
      conn: conn,
      user: user
    } do
      conn = get(conn, ~p"/#{user}/phone_numbers")
      html = html_response(conn, 200)

      # The legacy card shell still wraps it.
      assert html =~ ~s(class="card-list")
      assert html =~ ~s(<section class="card">)

      # The empty owner card is the dashed add tile linking into the new-route,
      # not the old card__empty line + bottom card__morelink.
      assert html =~ "data-empty-add"
      assert html =~ ~p"/#{user}/phone_numbers/new"
      refute html =~ ~s(class="card__morelink")
    end

    test "a non-owner sees no add affordance on someone else's empty index", %{conn: conn} do
      other = insert_activated_user()
      conn = get(conn, ~p"/#{other}/phone_numbers")
      html = html_response(conn, 200)

      # No add affordance for a visitor: the plain empty line, no dashed tile.
      assert html =~ ~s(<p class="card__empty">)
      refute html =~ "data-empty-add"
      refute html =~ ~s(class="card__morelink")
    end

    test "a new page wraps its form in the card section shell", %{conn: conn, user: user} do
      conn = get(conn, ~p"/#{user}/phone_numbers/new")
      html = html_response(conn, 200)

      assert html =~ ~s(class="card-list")
      assert html =~ ~s(<section class="card">)
      # The form_content is rendered inside the shell (its submit button is present).
      assert html =~ ~s(<button class="button" type="submit">)
    end
  end

  # The shared `<.row_actions>` component renders the calm, labeled per-entry
  # Edit/Delete actions on every management list and entry show page — the
  # unified replacement for the loud `.btns-right` pencil + red trash-circle
  # pair (`<.edit_delete_actions>`, still used by the admin tables). Edit is a
  # brand text link, Delete a muted-red text link that deletes through the
  # `delete` method (CSRF) behind a confirm prompt — never POST. The email
  # card_list (owner view) and the address show page are representative converted
  # sites; the address show test is also the regression for the bug where the old
  # delete control defaulted to POST (no POST route exists) and silently failed.
  describe "shared row actions (edit/delete)" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "the email card_list renders calm labeled Edit and Delete actions",
         %{conn: conn, user: user} do
      [email | _] = user.emails
      conn = get(conn, ~p"/#{user}/emails")
      html = html_response(conn, 200)

      # Calm labeled text actions, not the loud icon-glyph button pair.
      refute html =~ ~s(class="btns-right")
      refute html =~ ~s(<i class="icon icon--delete"></i>)
      refute html =~ "button--danger"

      # Edit links to the edit route; Delete deletes via the delete method
      # (edit-before-delete order is guaranteed by the row_actions component).
      assert html =~ ~s(href="#{~p"/#{user}/emails/#{email}/edit"}")
      assert html =~ ~s(data-method="delete")
    end

    test "the address show page deletes via the delete method, not POST",
         %{conn: conn, user: user} do
      address = insert(:address, user: user)
      conn = get(conn, ~p"/#{user}/addresses/#{address}")
      html = html_response(conn, 200)

      # Regression: the old delete control had no `method`, so it defaulted to
      # POST against a path that has no POST route. The calm Delete link still
      # emits the delete method (CSRF) against the entry path.
      assert html =~ ~s(data-method="delete")
      assert html =~ ~s(data-to="#{~p"/#{user}/addresses/#{address}"}")

      # Edit link present; the loud icon glyphs and danger button are gone.
      assert html =~ ~s(href="#{~p"/#{user}/addresses/#{address}/edit"}")
      refute html =~ ~s(<i class="icon icon--delete"></i>)
      refute html =~ "button--danger"
    end
  end
end
