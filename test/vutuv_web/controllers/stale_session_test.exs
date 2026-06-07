defmodule VutuvWeb.StaleSessionTest do
  @moduledoc """
  Cookies issued before the UUID v7 cutover store an integer `user_id`. Those
  sessions must degrade to logged-out (the visitor logs in again with a PIN),
  never crash the request or the shell (see `Vutuv.UUIDv7.cast_or_nil/1`).
  """
  use VutuvWeb.ConnCase

  test "an integer session user_id renders pages logged out instead of 500", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(user_id: 12_610)
      |> get(~p"/")

    # The page (and the shell embedded in the layout) renders anonymous chrome.
    assert html_response(conn, 200) =~ "Log in"
    assert conn.assigns.current_user == nil
  end

  test "a UUID session user_id still logs in", %{conn: conn} do
    user = insert(:user, validated?: true)

    conn =
      conn
      |> Plug.Test.init_test_session(user_id: user.id)
      |> get(~p"/")

    assert conn.assigns.current_user.id == user.id
  end
end
