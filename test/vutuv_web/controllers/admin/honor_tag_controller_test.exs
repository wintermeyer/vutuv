defmodule VutuvWeb.Admin.HonorTagControllerTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Repo
  alias Vutuv.Tags.Tag

  # The Honor tags overview: the discoverable admin home for the official-badge
  # feature. One-step create (name -> land on the roster) with a guard against
  # silently flipping a tag members already hold.

  describe "as an admin" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      {:ok, conn: conn, admin: admin}
    end

    test "index lists honor tags and links to the create form", %{conn: conn} do
      # A distinct name, not the "vutuv_developer" the intro/placeholder mention.
      insert(:tag, name: "vutuv_council", slug: "vutuv-council", honor?: true)
      insert(:tag, name: "elixir", slug: "elixir")

      html = conn |> get(~p"/admin/honor_tags") |> html_response(200)

      assert html =~ "vutuv_council"
      # A normal tag does not show here.
      refute html =~ ">elixir<"
      # The one-step create form posts to this page.
      assert html =~ ~s(action="/admin/honor_tags")
    end

    test "creating a new honor tag lands on its roster", %{conn: conn} do
      conn = post(conn, ~p"/admin/honor_tags", honor_tag: %{name: "vutuv_contributor"})

      assert redirected_to(conn) == ~p"/admin/tags/vutuv-contributor"
      tag = Repo.get_by(Tag, slug: "vutuv-contributor")
      assert tag.honor?
    end

    test "creating flips an existing holder-less tag", %{conn: conn} do
      tag = insert(:tag, name: "mentor", slug: "mentor")

      conn = post(conn, ~p"/admin/honor_tags", honor_tag: %{name: "mentor"})

      assert redirected_to(conn) == ~p"/admin/tags/mentor"
      assert Repo.reload(tag).honor?
    end

    test "creating a name members already hold routes to the edit warning, not a silent flip",
         %{conn: conn} do
      tag = insert(:tag, name: "elixir", slug: "elixir")
      insert(:user_tag, user: insert(:user), tag: tag)

      conn = post(conn, ~p"/admin/honor_tags", honor_tag: %{name: "elixir"})

      assert redirected_to(conn) == ~p"/admin/tags/elixir/edit"
      refute Repo.reload(tag).honor?
    end

    test "a spaced name is rejected", %{conn: conn} do
      conn = post(conn, ~p"/admin/honor_tags", honor_tag: %{name: "core team"})

      assert redirected_to(conn) == ~p"/admin/honor_tags"
      refute Repo.exists?(from(t in Tag, where: t.honor?))
    end
  end

  test "a non-admin cannot reach the honor tags page", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    conn = get(conn, ~p"/admin/honor_tags")
    assert conn.status == 403
  end
end
