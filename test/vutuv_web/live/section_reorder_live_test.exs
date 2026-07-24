defmodule VutuvWeb.SectionReorderLiveTest do
  @moduledoc """
  The owner's embedded reorder tool (`VutuvWeb.SectionReorderLive`). Both the
  drag-and-drop path (the JS hook pushes a "reorder" event with the new id
  order) and the up/down arrows ("move" phx-click) persist over the socket with
  no page reload. The authoritative owner is resolved from the cookie's
  `session_token` (never a bare `user_id`), so a remotely logged-out device or a
  suspended member can no longer reorder, and the tool can only ever renumber
  that member's own rows.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Accounts.Email
  alias Vutuv.Profiles.Language
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Profiles.Url
  alias Vutuv.Sessions

  # A real active session for the owner: the tool authenticates from the
  # cookie's session_token the way the embedded child sees it at mount, not a
  # page-supplied user_id.
  defp session_for(conn, user, extra) do
    {token, _session} = Sessions.start_session(user, conn, alert: false)
    Map.merge(%{"session_token" => token}, extra)
  end

  defp mount_tool(conn, user, section) do
    live_isolated(conn, VutuvWeb.SectionReorderLive,
      session: session_for(conn, user, %{"section" => section, "slug" => user.username})
    )
  end

  describe "links" do
    test "the disconnected render lists the entries in their chosen order", %{conn: conn} do
      user = insert_activated_user()
      insert(:url, user: user, description: "Bravo", position: 2)
      insert(:url, user: user, description: "Alpha", position: 1)

      {:ok, _view, html} = mount_tool(conn, user, "links")

      {alpha, _} = :binary.match(html, "Alpha")
      {bravo, _} = :binary.match(html, "Bravo")
      assert alpha < bravo
    end

    test "an up-arrow click swaps a link with its predecessor, no reload", %{conn: conn} do
      user = insert_activated_user()
      a = insert(:url, user: user, position: 1)
      b = insert(:url, user: user, position: 2)

      {:ok, view, _html} = mount_tool(conn, user, "links")

      view
      |> element("button[phx-value-id='#{b.id}'][phx-value-dir='up']")
      |> render_click()

      assert Repo.get(Url, b.id).position == 1
      assert Repo.get(Url, a.id).position == 2
    end

    test "a drag (reorder hook event) persists the submitted order", %{conn: conn} do
      user = insert_activated_user()
      a = insert(:url, user: user, position: 1)
      b = insert(:url, user: user, position: 2)
      c = insert(:url, user: user, position: 3)

      {:ok, view, _html} = mount_tool(conn, user, "links")

      render_hook(view, "reorder", %{"order" => [c.id, a.id, b.id]})

      assert Repo.get(Url, c.id).position == 1
      assert Repo.get(Url, a.id).position == 2
      assert Repo.get(Url, b.id).position == 3
    end

    test "reorder never touches another member's rows", %{conn: conn} do
      user = insert_activated_user()
      mine = insert(:url, user: user, position: 1)
      other = insert_activated_user()
      theirs = insert(:url, user: other, position: 1)

      {:ok, view, _html} = mount_tool(conn, user, "links")

      render_hook(view, "reorder", %{"order" => [theirs.id, mine.id]})

      assert Repo.get(Url, theirs.id).position == 1
      assert Repo.get(Url, mine.id).position == 1
    end
  end

  describe "phone numbers" do
    test "an up-arrow click reorders the owner's numbers", %{conn: conn} do
      user = insert_activated_user()
      a = insert(:phone_number, user: user, position: 1)
      b = insert(:phone_number, user: user, position: 2)

      {:ok, view, _html} = mount_tool(conn, user, "phone_numbers")

      view
      |> element("button[phx-value-id='#{b.id}'][phx-value-dir='up']")
      |> render_click()

      assert Repo.get(PhoneNumber, b.id).position == 1
      assert Repo.get(PhoneNumber, a.id).position == 2
    end
  end

  describe "emails" do
    test "the owner's tool lists private addresses too and reorders them", %{conn: conn} do
      user = insert_activated_user()
      pub = insert(:email, user: user, value: "pub@example.com", public?: true, position: 1)

      priv =
        insert(:email, user: user, value: "secret@example.com", public?: false, position: 2)

      {:ok, view, html} = mount_tool(conn, user, "emails")

      # The owner sees both, including the private one (the read-only public
      # view filters private addresses out; this management tool does not).
      assert html =~ "pub@example.com"
      assert html =~ "secret@example.com"

      view
      |> element("button[phx-value-id='#{priv.id}'][phx-value-dir='up']")
      |> render_click()

      assert Repo.get(Email, priv.id).position == 1
      assert Repo.get(Email, pub.id).position == 2
    end
  end

  describe "languages (issue #894)" do
    test "the tool lists each language with its proficiency badge", %{conn: conn} do
      user = insert_activated_user()
      insert(:language, user: user, language_code: "de", proficiency: "native", position: 1)

      {:ok, _view, html} = mount_tool(conn, user, "languages")

      assert html =~ "German"
      assert html =~ "Native"
      # The edit/delete links address the entry by its ISO code, not its UUID.
      assert html =~ "/settings/languages/de/edit"
    end

    test "an up-arrow click reorders the owner's languages, no reload", %{conn: conn} do
      user = insert_activated_user()
      de = insert(:language, user: user, language_code: "de", proficiency: "native", position: 1)
      en = insert(:language, user: user, language_code: "en", proficiency: "b2", position: 2)

      {:ok, view, _html} = mount_tool(conn, user, "languages")

      view
      |> element("button[phx-value-id='#{en.id}'][phx-value-dir='up']")
      |> render_click()

      assert Repo.get(Language, en.id).position == 1
      assert Repo.get(Language, de.id).position == 2
    end

    test "the first of 2+ languages is marked the preferred contact language", %{conn: conn} do
      user = insert_activated_user()
      insert(:language, user: user, language_code: "en", proficiency: "b2", position: 1)
      insert(:language, user: user, language_code: "de", proficiency: "native", position: 2)

      {:ok, _view, html} = mount_tool(conn, user, "languages")

      assert html =~ "Preferred contact language"
    end

    test "a lone language carries no preferred marker", %{conn: conn} do
      user = insert_activated_user()
      insert(:language, user: user, language_code: "en", proficiency: "b2", position: 1)

      {:ok, _view, html} = mount_tool(conn, user, "languages")

      refute html =~ "Preferred contact language"
    end
  end

  describe "authentication (issue #1036)" do
    # The tool must resolve its owner through the session token, so a device
    # that was remotely logged out (issue #794) or a suspended member cannot
    # keep reordering by reconnecting with the same cookie.
    test "a revoked device can no longer reorder", %{conn: conn} do
      user = insert_activated_user()
      a = insert(:url, user: user, position: 1)
      b = insert(:url, user: user, position: 2)

      {token, session} = Sessions.start_session(user, conn, alert: false)
      Sessions.revoke(session)

      {:ok, view, html} =
        live_isolated(conn, VutuvWeb.SectionReorderLive,
          session: %{"session_token" => token, "section" => "links", "slug" => user.username}
        )

      # No owner resolved, so nothing is listed and a forced reorder event is a
      # no-op: the positions stay put.
      refute html =~ "reorder-item-"
      render_hook(view, "reorder", %{"order" => [b.id, a.id]})

      assert Repo.get(Url, a.id).position == 1
      assert Repo.get(Url, b.id).position == 2
    end

    test "a suspended member can no longer reorder", %{conn: conn} do
      user = insert_activated_user()
      a = insert(:url, user: user, position: 1)
      b = insert(:url, user: user, position: 2)

      session = session_for(conn, user, %{"section" => "links", "slug" => user.username})

      Repo.update_all(from(u in Vutuv.Accounts.User, where: u.id == ^user.id),
        set: [suspended_until: NaiveDateTime.add(NaiveDateTime.utc_now(:second), 86_400)]
      )

      {:ok, view, html} =
        live_isolated(conn, VutuvWeb.SectionReorderLive, session: session)

      refute html =~ "reorder-item-"
      render_hook(view, "reorder", %{"order" => [b.id, a.id]})

      assert Repo.get(Url, a.id).position == 1
      assert Repo.get(Url, b.id).position == 2
    end

    test "a page-supplied user_id alone never authenticates", %{conn: conn} do
      # The replay: no token in the cookie, just a bare user_id the way the old
      # code trusted it. The tool must refuse it.
      user = insert_activated_user()
      a = insert(:url, user: user, position: 1)
      b = insert(:url, user: user, position: 2)

      {:ok, view, html} =
        live_isolated(conn, VutuvWeb.SectionReorderLive,
          session: %{"user_id" => user.id, "section" => "links", "slug" => user.username}
        )

      refute html =~ "reorder-item-"
      render_hook(view, "reorder", %{"order" => [b.id, a.id]})

      assert Repo.get(Url, a.id).position == 1
      assert Repo.get(Url, b.id).position == 2
    end
  end
end
