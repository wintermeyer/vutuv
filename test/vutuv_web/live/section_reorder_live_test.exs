defmodule VutuvWeb.SectionReorderLiveTest do
  @moduledoc """
  The owner's embedded reorder tool (`VutuvWeb.SectionReorderLive`). Both the
  drag-and-drop path (the JS hook pushes a "reorder" event with the new id
  order) and the up/down arrows ("move" phx-click) persist over the socket with
  no page reload. The authoritative owner is the session `user_id`, so the tool
  can only ever renumber that member's own rows.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Accounts.Email
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Profiles.Url

  defp mount_tool(conn, user, section) do
    live_isolated(conn, VutuvWeb.SectionReorderLive,
      session: %{"user_id" => user.id, "section" => section, "slug" => user.active_slug}
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
end
