defmodule VutuvWeb.GroupControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Social.Group

  # Regression: group/form_content.html.heex needs @backlink (the shared
  # <.form_actions> Cancel link), but new.html/edit.html never passed it, so
  # GET new/edit crashed with a KeyError instead of rendering the form. Found
  # in a browser smoke test; no test covered these pages before.

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, conn: conn, user: user}
  end

  test "GET new renders the group form", %{conn: conn, user: user} do
    conn = get(conn, ~p"/#{user}/groups/new")

    assert html = html_response(conn, 200)
    assert html =~ "editform__actions"
    assert html =~ ~p"/#{user}/groups"
  end

  test "GET edit renders the group form", %{conn: conn, user: user} do
    {:ok, group} =
      user
      |> Ecto.build_assoc(:groups)
      |> Group.changeset(%{"name" => "Mountain bikers"})
      |> Vutuv.Repo.insert()

    conn = get(conn, ~p"/#{user}/groups/#{group}/edit")

    assert html = html_response(conn, 200)
    assert html =~ "Mountain bikers"
    assert html =~ "editform__actions"
  end
end
