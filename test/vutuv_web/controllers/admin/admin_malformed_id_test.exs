defmodule VutuvWeb.Admin.MalformedIdTest do
  @moduledoc """
  Admin ids come off a URL, so a truncated paste or an edited address reaches
  `Repo.get` as a non-UUID — which raises `Ecto.CastError` and answers 500.

  `ControllerHelpers.get_user/1` exists for exactly this and says so: *"a
  garbage (non-UUID) id is a no-op, never an `Ecto.CastError` 500"*. Three admin
  actions went straight to `Repo.get`/`Repo.get!` beside it, so their own
  `nil -> render_error(conn, 404)` branch was unreachable for the one input that
  needed it.

  Calibrated against the un-fixed code, where each of these is a 500.
  """
  use VutuvWeb.ConnCase, async: true

  @malformed "not-a-uuid"

  test "thawing a frozen account by a malformed id is a 404", %{conn: conn} do
    {conn, _admin} = create_and_login_admin(conn)

    assert conn |> post(~p"/admin/deliverability/users/#{@malformed}/thaw") |> response(404)
  end

  test "clearing an address by a malformed id is a 404", %{conn: conn} do
    {conn, _admin} = create_and_login_admin(conn)

    assert conn
           |> post(~p"/admin/deliverability/emails/#{@malformed}/clear")
           |> response(404)
  end

  test "verifying a member by a malformed id is a 404", %{conn: conn} do
    {conn, _admin} = create_and_login_admin(conn)

    assert conn
           |> post(~p"/admin/users", %{"user_id" => @malformed})
           |> response(404)
  end
end
