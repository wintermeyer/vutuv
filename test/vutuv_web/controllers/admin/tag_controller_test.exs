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

  describe "search" do
    test "filters the listing by name (case-insensitive substring)", %{conn: conn} do
      insert(:tag, name: "Elixir", slug: "elixir")
      insert(:tag, name: "Ruby", slug: "ruby")

      html = conn |> get(~p"/admin/tags?q=eli") |> html_response(200)
      assert html =~ "Elixir"
      refute html =~ "Ruby"
    end

    test "filters the listing by slug", %{conn: conn} do
      insert(:tag, name: "C Sharp", slug: "c-sharp")
      insert(:tag, name: "Go", slug: "golang")

      html = conn |> get(~p"/admin/tags?q=c-sharp") |> html_response(200)
      assert html =~ "C Sharp"
      refute html =~ "golang"
    end

    test "an empty query lists every tag", %{conn: conn} do
      insert(:tag, name: "Elixir", slug: "elixir")
      insert(:tag, name: "Ruby", slug: "ruby")

      html = conn |> get(~p"/admin/tags?q=") |> html_response(200)
      assert html =~ "Elixir"
      assert html =~ "Ruby"
    end

    test "shows a no-results notice when nothing matches", %{conn: conn} do
      insert(:tag, name: "Elixir", slug: "elixir")

      html = conn |> get(~p"/admin/tags?q=zzznope") |> html_response(200)
      refute html =~ "Elixir"
      assert html =~ "No tags match"
    end

    test "a LIKE metacharacter in the query is treated literally", %{conn: conn} do
      insert(:tag, name: "Elixir", slug: "elixir")

      # An unescaped "%" would match everything; escaped it matches nothing here.
      html = conn |> get(~p"/admin/tags?q=%25") |> html_response(200)
      refute html =~ "Elixir"
      assert html =~ "No tags match"
    end

    test "a crafted non-string query does not 500", %{conn: conn} do
      insert(:tag, name: "Elixir", slug: "elixir")

      # `?q[x]=1` parses into a map; it must be ignored, not crash to_string/1.
      html = conn |> get("/admin/tags?q[x]=1") |> html_response(200)
      assert html =~ "Elixir"
    end

    test "pagination keeps the search filter", %{conn: conn} do
      insert_list(250, :tag)
      insert(:tag, name: "Tag Zzz Marker", slug: "tag-zzz-marker")

      page1 = conn |> get(~p"/admin/tags?q=tag") |> html_response(200)
      refute page1 =~ "tag-zzz-marker"
      assert page1 =~ "q=tag"
      assert page1 =~ "page=2"

      page2 = conn |> recycle() |> get(~p"/admin/tags?q=tag&page=2") |> html_response(200)
      assert page2 =~ "tag-zzz-marker"
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
