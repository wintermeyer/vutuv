defmodule VutuvWeb.UserControllerTest do
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

  test "there is no public user directory (GET /users does not route)", %{conn: conn} do
    # The index action was dead code (its slug plug 404'd it) and its template
    # offered per-row Edit/Delete it could never authorize, so it was removed
    # outright. Admins list users at /admin; everyone else searches. Without
    # the route, /users falls into the catch-all vanity-slug redirect and
    # ends up a 404, like any other unknown path.
    {conn, _user} = create_and_login_user(conn)

    conn = get(conn, "/users")
    assert redirected_to(conn, 301) == "/users/users"
    assert conn |> recycle() |> get("/users/users") |> html_response(404)
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

  test "renders 403 when editing or updating another user's profile", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    other = insert(:user, validated?: true)
    insert(:slug, value: other.active_slug, disabled: false, user: other)

    assert conn |> get(~p"/users/#{other}/edit") |> html_response(403)

    assert conn
           |> recycle()
           |> put(~p"/users/#{other}", user: @update_attrs)
           |> html_response(403)
  end

  test "does not update chosen resource and renders errors when data is invalid", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    conn = put(conn, ~p"/users/#{user}", user: @invalid_update_attrs)
    assert html_response(conn, 200) =~ "Edit"
  end

  test "deletes chosen resource after confirming the PIN", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    # Step 1: request deletion. Nothing is deleted yet; a PIN is mailed and the
    # confirmation form is shown.
    conn = delete(conn, ~p"/users/#{user}")
    assert html_response(conn, 200) =~ "PIN"
    assert Repo.get(User, user.id)

    assert_received {:email, email}
    [pin] = Regex.run(~r/\b\d{6}\b/, email.text_body)

    # Step 2: submit the PIN. Now the account is gone.
    conn = post(conn, ~p"/account_deletion", account_deletion: %{pin: pin})
    assert redirected_to(conn) == ~p"/"
    refute Repo.get(User, user.id)
  end

  test "does not delete the account when the PIN is wrong", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    conn = delete(conn, ~p"/users/#{user}")
    assert_received {:email, _email}

    conn = post(conn, ~p"/account_deletion", account_deletion: %{pin: "000000"})
    assert html_response(conn, 200) =~ "PIN"
    assert Repo.get(User, user.id)
  end
end
