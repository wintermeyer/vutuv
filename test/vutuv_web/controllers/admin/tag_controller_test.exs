defmodule VutuvWeb.Admin.TagControllerTest do
  use VutuvWeb.ConnCase, async: true

  # The admin tag CRUD pages resolve the `:slug` param to a `Tags.Tag` before
  # every action. An unknown slug must render a clean 404 and *halt*; the
  # collection actions (:index, :new, :create) carry no `:slug` param so the
  # resolver must pass through there. These guard the swap to the shared
  # resolver plug.

  setup %{conn: conn} do
    {conn, admin} = create_and_login_admin(conn)
    {:ok, conn: conn, admin: admin}
  end

  describe "index (no slug param)" do
    test "renders the admin tag listing", %{conn: conn} do
      insert(:tag, name: "Elixir", slug: "elixir")
      conn = get(conn, ~p"/admin/tags")
      assert conn.status == 200
    end
  end

  describe "show" do
    test "renders an existing tag", %{conn: conn} do
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      conn = get(conn, ~p"/admin/tags/#{tag}")
      assert conn.status == 200
    end

    test "returns a clean 404 on an unknown slug", %{conn: conn} do
      conn = get(conn, ~p"/admin/tags/does-not-exist")
      assert conn.status == 404
      assert conn.halted
    end
  end

  describe "edit" do
    test "returns a clean 404 on an unknown slug", %{conn: conn} do
      conn = get(conn, ~p"/admin/tags/does-not-exist/edit")
      assert conn.status == 404
      assert conn.halted
    end
  end
end
