defmodule VutuvWeb.PersonalNotesLiveTest do
  @moduledoc """
  The member's private notes at `/system/notes` (`VutuvWeb.PersonalNotesLive`):
  the whole list, the live search, the page for one account with its form, and
  the paging a long list needs.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.PersonalNotes

  defp note!(author, subject, body) do
    {:ok, note} = PersonalNotes.create(author, subject, %{"body" => body})
    note
  end

  defp bodies(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#notes [data-personal-note] .markdown")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  test "a visitor is sent to the login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/system/notes")
  end

  test "lists the member's notes, newest first, with who each is about", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    ada = insert_activated_user(first_name: "Ada", last_name: "Lovelace")
    page = insert(:organization, name: "Analytical Engines")
    other = insert_activated_user()

    note!(viewer, ada, "first")
    note!(viewer, page, "second")
    note!(other, ada, "not mine")

    {:ok, view, _html} = live(conn, ~p"/system/notes")

    assert bodies(view) == ["second", "first"]
    assert has_element?(view, ~s(#notes [data-note-subject="member"]), "Ada Lovelace")
    assert has_element?(view, ~s(#notes [data-note-subject="organization"]), "Analytical Engines")
    refute render(view) =~ "not mine"
  end

  # A German reader gets German words, each written by hand: a gettext merge
  # fuzzy-filled "Add a personal note" with "Eltern-Tag hinzufügen".
  test "speaks German to a German reader", %{conn: conn} do
    {conn, _viewer} = create_and_login_user(conn)
    ada = insert_activated_user()

    conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de")
    {:ok, view, _html} = live(conn, ~p"/system/notes?member=#{ada.id}")
    html = render(view)

    assert html =~ "Persönliche Notizen"
    assert html =~ "Notizen zu"
    assert html =~ "Notizen durchsuchen"
    assert html =~ "Nur für Sie sichtbar"
    assert html =~ "Was möchten Sie sich merken?"
    assert html =~ "Noch keine Notizen zu diesem Konto."
    assert html =~ "Alle Ihre Notizen"

    {:ok, profile, _html} = live(conn, ~p"/#{ada}")
    assert render(profile) =~ "Persönliche Notiz hinzufügen"
  end

  test "the account menu leads to the notes on every page", %{conn: conn} do
    {conn, _viewer} = create_and_login_user(conn)

    links =
      conn
      |> get(~p"/feed")
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(#account-menu a[data-personal-notes-link][href="/system/notes"]))

    assert Enum.count(links) == 1
  end

  test "an empty list says where notes are written", %{conn: conn} do
    {conn, _viewer} = create_and_login_user(conn)

    {:ok, view, _html} = live(conn, ~p"/system/notes")

    assert has_element?(view, "#notes-empty", "Add a personal note")
  end

  test "searches as the member types, and the term rides the URL", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    ada = insert_activated_user(first_name: "Ada")
    grace = insert_activated_user(first_name: "Grace", last_name: "Hopper")

    note!(viewer, ada, "met at the Konferenz")
    note!(viewer, grace, "compiler pioneer")

    {:ok, view, _html} = live(conn, ~p"/system/notes")

    view |> form("#notes-search", %{q: "konferenz"}) |> render_change()
    assert_patch(view, ~p"/system/notes?q=konferenz")
    assert bodies(view) == ["met at the Konferenz"]

    view |> form("#notes-search", %{q: "hopper"}) |> render_change()
    assert bodies(view) == ["compiler pioneer"]

    view |> form("#notes-search", %{q: "nothing like it"}) |> render_change()
    assert bodies(view) == []
    assert has_element?(view, "#notes-empty", "No note matches")

    view |> form("#notes-search", %{q: ""}) |> render_change()
    assert_patch(view, ~p"/system/notes")
    assert length(bodies(view)) == 2
  end

  test "pages a long list twenty at a time", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    ada = insert_activated_user()
    for n <- 1..25, do: note!(viewer, ada, "note #{n}")

    {:ok, view, _html} = live(conn, ~p"/system/notes")

    first = bodies(view)
    assert length(first) == 20
    assert hd(first) == "note 25"

    view |> element("#load-more") |> render_click()

    all = bodies(view)
    assert length(all) == 25
    assert List.last(all) == "note 1"
    refute has_element?(view, "#load-more")
  end

  test "the page for one account writes a note about it", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    ada = insert_activated_user(first_name: "Ada")
    grace = insert_activated_user()
    note!(viewer, grace, "about grace")

    {:ok, view, _html} = live(conn, ~p"/system/notes?member=#{ada.id}")

    # Nothing about Ada yet, so the form is already open.
    assert has_element?(view, "#notes-subject", "Ada")
    assert has_element?(view, "#notes-new")
    assert bodies(view) == []

    view
    |> form("#notes-new", %{note: %{body: "Talked about **Elixir**"}})
    |> render_submit()

    assert [%{body: "Talked about **Elixir**"}] = PersonalNotes.recent(viewer, ada, 5)
    assert bodies(view) == ["Talked about Elixir"]
    refute has_element?(view, "#notes-new")
    refute render(view) =~ "about grace"
  end

  test "a note written and deleted again brings the empty line back", %{conn: conn} do
    {conn, _viewer} = create_and_login_user(conn)
    ada = insert_activated_user()

    {:ok, view, _html} = live(conn, ~p"/system/notes?member=#{ada.id}")
    assert has_element?(view, "#notes-empty")

    view |> form("#notes-new", %{note: %{body: "short-lived"}}) |> render_submit()
    refute has_element?(view, "#notes-empty")

    view |> element("#notes [id$=-delete]") |> render_click()
    assert has_element?(view, "#notes-empty")
  end

  test "searching leaves an open form open", %{conn: conn} do
    {conn, _viewer} = create_and_login_user(conn)
    ada = insert_activated_user()

    {:ok, view, _html} = live(conn, ~p"/system/notes?member=#{ada.id}")
    assert has_element?(view, "#notes-new")

    view |> form("#notes-search", %{q: "anything"}) |> render_change()

    assert has_element?(view, "#notes-new")
  end

  test "a guessed id of somebody hidden shows nobody", %{conn: conn} do
    {conn, _viewer} = create_and_login_user(conn)
    hidden = insert(:user, first_name: "Hidden")

    {:ok, view, _html} = live(conn, ~p"/system/notes?member=#{hidden.id}")

    refute has_element?(view, "#notes-subject")
    refute render(view) =~ "Hidden"
  end

  test "an empty note is refused with a reason", %{conn: conn} do
    {conn, _viewer} = create_and_login_user(conn)
    ada = insert_activated_user()

    {:ok, view, _html} = live(conn, ~p"/system/notes?member=#{ada.id}")

    view |> form("#notes-new", %{note: %{body: "   "}}) |> render_submit()

    assert has_element?(view, "#notes-new [data-note-error]")
  end

  test "edits a note in place and marks it edited", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    ada = insert_activated_user()
    note = note!(viewer, ada, "draft text")

    {:ok, view, _html} = live(conn, ~p"/system/notes")

    view |> element("#notes-#{note.id}-edit") |> render_click()
    assert has_element?(view, "#notes-#{note.id}-form")

    view
    |> form("#notes-#{note.id}-form", %{note: %{body: "final text"}})
    |> render_submit()

    refute has_element?(view, "#notes-#{note.id}-form")
    assert bodies(view) == ["final text"]
    assert has_element?(view, "#notes-#{note.id} [data-note-edited]")
  end

  test "deletes a note", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    ada = insert_activated_user()
    note = note!(viewer, ada, "gone soon")

    {:ok, view, _html} = live(conn, ~p"/system/notes")

    view |> element("#notes-#{note.id}-delete") |> render_click()

    refute has_element?(view, "#notes-#{note.id}")
    assert has_element?(view, "#notes-empty")
    assert PersonalNotes.count(viewer, ada) == 0
  end

  test "somebody else's note cannot be edited or deleted by id", %{conn: conn} do
    {conn, _viewer} = create_and_login_user(conn)
    owner = insert_activated_user()
    note = note!(owner, insert_activated_user(), "private")

    {:ok, view, _html} = live(conn, ~p"/system/notes")

    render_hook(view, "delete", %{"id" => note.id})
    render_hook(view, "update", %{"note_id" => note.id, "note" => %{"body" => "hacked"}})

    assert PersonalNotes.get(owner, note.id).body == "private"
  end
end
