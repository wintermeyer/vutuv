defmodule VutuvWeb.PersonalNotesPanelTest do
  @moduledoc """
  The "Personal notes" panel (`VutuvWeb.PersonalNotesComponent`) on the three
  pages an account has here: a member's profile, an organization page and a
  remote account's page. Private above all: the account the notes are about,
  another member and a visitor never see them.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Vutuv.MastodonHelpers, only: [remote_account: 1]

  alias Vutuv.PersonalNotes

  defp note!(author, subject, body) do
    {:ok, note} = PersonalNotes.create(author, subject, %{"body" => body})
    note
  end

  defp fresh_conn, do: build_conn() |> Plug.Test.init_test_session(%{})

  defp panel_visible?(view), do: has_element?(view, "#personal-notes:not([hidden])")

  # The panel's text as the browser gets it. `has_element?/3`'s text filter
  # reads the test proxy's own tree, which answered true for a note this panel
  # does not render, so the negative checks read the rendered HTML instead.
  defp panel_text(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#personal-notes")
    |> LazyHTML.text()
  end

  describe "on a member's profile" do
    test "stays hidden until the ⋯ menu asks for a note, then saves one", %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      ada = insert_activated_user()

      {:ok, view, _html} = live(conn, ~p"/#{ada}")

      assert has_element?(view, "#personal-notes[hidden]")
      refute has_element?(view, "#personal-notes-new")

      view |> element("#add-personal-note") |> render_click()

      assert panel_visible?(view)
      assert has_element?(view, "#personal-notes-new")

      view
      |> form("#personal-notes-new", %{note: %{body: "Met at the meetup"}})
      |> render_submit()

      refute has_element?(view, "#personal-notes-new")
      assert has_element?(view, "#personal-notes [data-personal-note]", "Met at the meetup")
      assert [%{body: "Met at the meetup"}] = PersonalNotes.recent(viewer, ada, 3)
    end

    test "shows the newest three and links to the rest", %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      ada = insert_activated_user()
      for word <- ~w(alpha bravo charlie delta), do: note!(viewer, ada, word)

      {:ok, view, _html} = live(conn, ~p"/#{ada}")

      assert panel_visible?(view)
      text = panel_text(view)
      assert text =~ "delta"
      assert text =~ "bravo"
      refute text =~ "alpha"

      assert has_element?(
               view,
               ~s(#personal-notes a[href="/system/notes?member=#{ada.id}"]),
               "Show all 4 notes"
             )
    end

    test "edits and deletes a note without leaving the page", %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)
      ada = insert_activated_user()
      note = note!(viewer, ada, "first try")
      row = "#personal-notes-note-#{note.id}"

      {:ok, view, _html} = live(conn, ~p"/#{ada}")

      view |> element("#{row} [data-note-edit]") |> render_click()

      view
      |> form("#{row}-form", %{note: %{body: "second try"}})
      |> render_submit()

      assert has_element?(view, row, "second try")
      assert has_element?(view, "#{row} [data-note-edited]")

      view |> element("#{row} [data-note-delete]") |> render_click()

      refute has_element?(view, row)
      assert has_element?(view, "#personal-notes[hidden]")
      assert PersonalNotes.count(viewer, ada) == 0
    end

    test "a note typed into a reopened form survives a reconnect", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      ada = insert_activated_user()

      {:ok, view, _html} = live(conn, ~p"/#{ada}")
      view |> element("#add-personal-note") |> render_click()

      # What LiveView's form recovery sends on a rejoin: the form's `phx-change`
      # with the values still in the DOM.
      view
      |> form("#personal-notes-new", %{note: %{body: "half written"}})
      |> render_change()

      assert has_element?(view, "#personal-notes-new")
    end

    test "nobody else sees the notes, the member they are about included", %{conn: conn} do
      {ada_conn, ada} = create_and_login_user(conn)
      author = insert_activated_user()
      note!(author, ada, "strictly private")

      {:ok, own, _html} = live(ada_conn, ~p"/#{ada}")
      refute render(own) =~ "strictly private"
      refute has_element?(own, "#personal-notes")

      {other_conn, _other} = create_and_login_user(fresh_conn())
      {:ok, other, _html} = live(other_conn, ~p"/#{ada}")
      refute render(other) =~ "strictly private"
      assert has_element?(other, "#personal-notes[hidden]")

      {:ok, anonymous, _html} = live(fresh_conn(), ~p"/#{ada}")
      refute render(anonymous) =~ "strictly private"
      refute has_element?(anonymous, "#personal-notes")
    end
  end

  test "an organization page opens the same panel", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    page = insert(:organization)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{page.slug}")

    view |> element("#add-personal-note") |> render_click()

    view
    |> form("#personal-notes-new", %{note: %{body: "Their press contact is Jana"}})
    |> render_submit()

    assert has_element?(view, "#personal-notes", "Their press contact is Jana")
    assert PersonalNotes.count(viewer, page) == 1
  end

  test "a remote account's page opens the same panel", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    account = remote_account(handle: "someone")

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/account/#{account.id}")

    view |> element("#add-personal-note") |> render_click()

    view
    |> form("#personal-notes-new", %{note: %{body: "Fosstodon, asked for notes"}})
    |> render_submit()

    assert has_element?(view, "#personal-notes", "Fosstodon, asked for notes")
    assert PersonalNotes.count(viewer, account) == 1
  end
end
