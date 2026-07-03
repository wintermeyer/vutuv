defmodule VutuvWeb.UsernameControllerTest do
  @moduledoc """
  Changing the username (@handle). One owner-only page: the change form with
  the live availability check and the visible quota (4 changes per 90 days).
  Renaming frees the old handle - no redirect, no reservation - so the old
  profile URL simply 404s afterwards.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Accounts.User

  describe "authorization" do
    test "the username page is owner-only", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      other = insert_activated_user()

      assert conn |> get("/#{other.username}/usernames/new") |> html_response(403)
    end

    test "guests cannot see or use the username page", %{conn: conn} do
      user = insert_activated_user()

      assert conn |> get("/#{user.username}/usernames/new") |> html_response(403)

      conn = post(conn, "/#{user.username}/usernames", user: %{"username" => "hijacked"})
      assert conn.status == 403
      refute Repo.get(User, user.id).username == "hijacked"
    end
  end

  describe "the change form" do
    test "shows the current handle and the quota", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      html = conn |> get("/#{user.username}/usernames/new") |> html_response(200)

      assert html =~ "@#{user.username}"
      assert html =~ ~s(id="slug-form")
      # The changeset wraps the persisted user, so the form would infer PUT
      # (a hidden _method override) - but the route is a plain POST create.
      refute html =~ ~s(name="_method")
      # The limit is spelled out, and so is what is left of it.
      assert html =~ gettext("You can change your username up to 4 times within 90 days.")
      assert html =~ gettext("4 of 4 changes left.")
    end

    test "with the quota used up it shows the next possible date, not the form", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      db_user = Repo.get(User, user.id)

      for n <- 1..4 do
        {:ok, _} = Vutuv.Accounts.update_username(db_user, %{"username" => "used_up_#{n}"})
      end

      html = conn |> get("/used_up_4/usernames/new") |> html_response(200)

      refute html =~ ~s(id="slug-form")
      assert html =~ gettext("You have used all 4 username changes of the last 90 days.")
    end
  end

  describe "create (changing the username)" do
    test "renames the account; the old URL is freed and 404s", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      old_handle = user.username

      conn = post(conn, "/#{old_handle}/usernames", user: %{"username" => "Brand_New"})

      assert redirected_to(conn) == "/brand_new"
      assert Repo.get(User, user.id).username == "brand_new"

      assert conn |> get("/brand_new") |> html_response(200)
      # No redirect, no reservation: the old handle is gone.
      assert get(conn, "/#{old_handle}").status == 404
    end

    test "an invalid handle re-renders the form with the error", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = post(conn, "/#{user.username}/usernames", user: %{"username" => "not valid!"})

      assert html_response(conn, 200) =~ "may only contain letters, numbers, and underscores"
      assert Repo.get(User, user.id).username == user.username
    end

    test "a handle in use by someone else re-renders with the error", %{conn: conn} do
      insert(:user, username: "wanted_handle")
      {conn, user} = create_and_login_user(conn)

      conn = post(conn, "/#{user.username}/usernames", user: %{"username" => "wanted_handle"})

      assert html_response(conn, 200) =~ "has already been taken"
    end

    test "an exhausted quota refuses the change", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      db_user = Repo.get(User, user.id)

      for n <- 1..4 do
        {:ok, _} = Vutuv.Accounts.update_username(db_user, %{"username" => "spent_#{n}"})
      end

      conn = post(conn, "/spent_4/usernames", user: %{"username" => "one_too_many"})

      assert conn.status == 200
      assert Repo.get(User, user.id).username == "spent_4"
    end
  end

  describe "availability check" do
    test "answers free, taken, and invalid", %{conn: conn} do
      insert(:user, username: "claimed_handle")
      {conn, user} = create_and_login_user(conn)
      base = "/#{user.username}/usernames/availability"

      # The route lives in the :browser pipeline (`accepts ["html"]`), so the
      # form's fetch() must negotiate via its default */* Accept header - an
      # explicit "application/json" would 406. Pin that here.
      conn = conn |> recycle() |> put_req_header("accept", "*/*")

      assert %{"available" => true} = json_response(get(conn, base <> "?value=free_handle"), 200)

      assert %{"available" => false, "message" => taken_msg} =
               json_response(get(conn, base <> "?value=claimed_handle"), 200)

      assert taken_msg =~ "taken"

      assert %{"available" => false} = json_response(get(conn, base <> "?value=no!good"), 200)
      assert %{"available" => false} = json_response(get(conn, base <> "?value=login"), 200)
    end
  end

  describe "discoverability" do
    test "the sign-in & security page shows the current username and links to the change flow", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)

      # The username lives on the sign-in & security page of Settings.
      html = conn |> get("/#{user.username}/settings/security") |> html_response(200)

      assert html =~ "@#{user.username}"
      assert html =~ "/#{user.username}/usernames/new"
    end
  end

  defp gettext(msgid), do: Gettext.gettext(VutuvWeb.Gettext, msgid)
end
