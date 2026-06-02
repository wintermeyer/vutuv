defmodule Vutuv.Accounts.UserControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Accounts.User

  @valid_attrs %{
    "emails" => %{"0" => %{"value" => "email@example.com"}},
    "first_name" => "first_name"
  }
  @update_attrs [first_name: "new_first_name"]
  @invalid_update_attrs [first_name: nil, last_name: nil]
  @invalid_attrs %{
    "emails" => %{"0" => %{"value" => nil}},
    "first_name" => nil,
    "gender" => "male",
    "last_name" => nil
  }

  test "creates resource when valid and redirects", %{conn: conn} do
    conn = post(conn, ~p"/new_registration", user: @valid_attrs)

    assert Repo.one(
             from(u in User,
               join: e in assoc(u, :emails),
               where: e.value == ^@valid_attrs["emails"]["0"]["value"]
             )
           )

    assert html_response(conn, 200) =~ "INBOX"
  end

  test "renders form for new resources", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Sign up"
  end

  test "does not create resource and renders errors when data is invalid", %{conn: conn} do
    conn = post(conn, ~p"/new_registration", user: @invalid_attrs)
    assert html_response(conn, 200) =~ "Sign up"
  end

  test "shows chosen resource", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    conn = get(conn, ~p"/users/#{user}")
    assert html_response(conn, 200) =~ user.first_name
  end

  test "renders page not found when id is nonexistent", %{conn: conn} do
    conn = get(conn, ~p"/users/#{%User{active_slug: "1"}}")
    assert html_response(conn, :not_found)
  end

  test "renders form for editing chosen resource", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    conn = get(conn, ~p"/users/#{user}/edit")
    assert html_response(conn, 200) =~ "Edit"
  end

  test "updates chosen resource and redirects when data is valid", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    conn = put(conn, ~p"/users/#{user}", user: @update_attrs)
    assert redirected_to(conn) == ~p"/users/#{user}"
    assert Repo.get_by(User, @update_attrs)
  end

  test "does not update chosen resource and renders errors when data is invalid", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    conn = put(conn, ~p"/users/#{user}", user: @invalid_update_attrs)
    assert html_response(conn, 200) =~ "Edit"
  end

  test "deletes chosen resource", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    conn = delete(conn, ~p"/users/#{user}")

    link =
      Repo.one(
        from(m in Vutuv.Accounts.MagicLink,
          where: m.user_id == ^user.id and m.magic_link_type == "delete",
          select: m.magic_link
        )
      )

    conn = get(conn, ~p"/magic/delete/#{link}")
    assert redirected_to(conn) == ~p"/"
    refute Repo.get(User, user.id)
  end
end
