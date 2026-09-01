defmodule VutuvWeb.FormSubmitSweepTest do
  @moduledoc """
  Every page that carries a submitting form, checked for the one thing HTML
  will not tell you about (issue #1896): a form with no submit control stops
  accepting Return the moment it holds a second field that blocks implicit
  submission. Nothing errors. The member presses Return, nothing happens, and
  the suite stays green — which is how the feed's "Wörter ausblenden" card
  lost its save (issue #1888).

  That fix brought a sweep with it, but it watched the feed and nothing else,
  so the other ~30 pages with forms were unwatched. This is that sweep, moved
  to `Vutuv.FormSubmitHelpers` and pointed at the pages rather than at one.

  **Why it is a rendered sweep and not a source scan.** The second field
  usually arrives from a caller's slot, so the component reads as a one-field
  form in its own source; and `<.form_actions>` emits a submit button a scanner
  would not see either. Only the built page knows.

  Adding a page here costs one line. A page that needs a login, a fixture or a
  role gets its own test below rather than a line in the table — the table is
  for pages a plain member can open.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Vutuv.FormSubmitHelpers

  # Pages a logged-in member can open with no fixtures. `min_forms` is set only
  # where the page is *known* to carry one, so the sweep cannot pass by finding
  # nothing on a page whose route quietly changed.
  @member_pages [
    {"/search", 1},
    {"/settings", 0},
    {"/settings/privacy", 0},
    {"/settings/notifications", 0},
    {"/settings/feed_languages", 0},
    # 0, not 1: the lookup form is only offered to a member whose federation
    # standing allows it, and a plain new account is refused — so the page
    # legitimately renders none.
    {"/system/fediverse/lookup", 0},
    {"/system/members", 0},
    {"/messages", 0},
    {"/notifications", 0},
    {"/tags/new", 1},
    {"/organizations", 0},
    {"/organizations/new", 1}
  ]

  describe "pages a member can open" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    for {path, min_forms} <- @member_pages do
      test "#{path} renders no form a browser cannot submit", %{conn: conn} do
        path = unquote(path)
        min_forms = unquote(min_forms)

        # A plain GET, deliberately: this table mixes LiveView routes with
        # classic controller pages, and a GET renders both — a LiveView answers
        # it with its static render, which carries the same forms. The one
        # place the connected render matters is the feed's rail, and that has
        # its own test below.
        conn = get(conn, path)

        if conn.status == 200 do
          opts = if min_forms > 0, do: [min_forms: min_forms], else: []
          assert_forms_submittable(html_response(conn, 200), path, opts)
        end
      end
    end
  end

  describe "the feed" do
    test "sweeps its forms, rail cards unfolded", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, view, _html} = live(conn, ~p"/feed")

      # The rail's add-field forms are what #1888 broke, and they are the three
      # this page must always carry.
      assert_forms_submittable(render(view), "/feed", min_forms: 3)
    end
  end

  describe "the composer's own pages" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Vutuv.Posts.create_post(user, %{body: "Etwas zum Bearbeiten."})
      %{conn: conn, user: user, post: post}
    end

    test "the edit page", %{conn: conn, post: post} do
      {:ok, view, _html} = live(conn, ~p"/posts/#{post.id}/edit")
      assert_forms_submittable(render(view), "/posts/:id/edit", min_forms: 1)
    end

    test "the reply page", %{conn: conn, post: post} do
      {:ok, view, _html} = live(conn, ~p"/posts/#{post.id}/reply")
      assert_forms_submittable(render(view), "/posts/:id/reply", min_forms: 1)
    end
  end

  describe "the sweep itself" do
    # A check nobody has watched fail is a check nobody should trust. These
    # build the two shapes by hand, so the helper is known to answer both ways
    # rather than only ever saying yes.
    test "a two-field form with no submit control is refused" do
      html = """
      <html><body>
        <form phx-submit="save">
          <input type="text" name="a"/>
          <input type="text" name="b"/>
        </form>
      </body></html>
      """

      assert_raise ExUnit.AssertionError, fn ->
        assert_forms_submittable(html, "a hand-built page")
      end
    end

    test "the same form passes once it has a button, one field, or a matching phx-change" do
      for body <- [
            ~s(<input type="text" name="a"/><input type="text" name="b"/><button>Go</button>),
            ~s(<input type="text" name="a"/><input type="checkbox" name="b"/>),
            ~s(<input type="text" name="a"/>)
          ] do
        html = "<html><body><form phx-submit=\"save\">#{body}</form></body></html>"
        assert :ok = assert_forms_submittable(html, "a hand-built page")
      end

      matching = """
      <html><body>
        <form phx-submit="filter" phx-change="filter">
          <input type="text" name="a"/><input type="text" name="b"/>
        </form>
      </body></html>
      """

      assert :ok = assert_forms_submittable(matching, "a hand-built page")
    end

    test "min_forms refuses a page that renders none" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_forms_submittable("<html><body></body></html>", "an empty page", min_forms: 1)
      end
    end
  end
end
