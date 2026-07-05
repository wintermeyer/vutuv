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

    test "paginates: rows past the first page land on page 2", %{conn: conn} do
      # 250/page (max_page_items); the slug-ordered listing puts the marker last.
      insert_list(250, :tag)
      insert(:tag, name: "Zzz Marker", slug: "zzz-marker")

      page1 = conn |> get(~p"/admin/tags") |> html_response(200)
      refute page1 =~ "zzz-marker"
      assert page1 =~ "page=2"

      page2 = conn |> recycle() |> get(~p"/admin/tags?page=2") |> html_response(200)
      assert page2 =~ "zzz-marker"
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

    test "the edit form offers the honor checkbox", %{conn: conn} do
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      html = conn |> get(~p"/admin/tags/#{tag}/edit") |> html_response(200)
      assert html =~ ~s(name="tag[honor?]")
    end
  end

  describe "the honor flag" do
    test "the edit form persists it both on and off", %{conn: conn} do
      tag = insert(:tag, name: "Elixir", slug: "elixir")

      conn = put(conn, ~p"/admin/tags/#{tag}", tag: %{"honor?" => "true"})
      assert redirected_to(conn) == ~p"/admin/tags/#{tag}"
      assert Repo.reload(tag).honor?

      conn = conn |> recycle() |> put(~p"/admin/tags/#{tag}", tag: %{"honor?" => "false"})
      assert redirected_to(conn) == ~p"/admin/tags/#{tag}"
      refute Repo.reload(tag).honor?
    end
  end
end
