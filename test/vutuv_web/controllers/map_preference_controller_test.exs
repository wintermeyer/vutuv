defmodule VutuvWeb.MapPreferenceControllerTest do
  @moduledoc """
  The click-to-promote endpoint: opening a non-default map service on a profile
  makes it the viewer's new default (fired by the MapLinks enhancement in
  app.js). Logged-in only.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts.User

  test "POST promotes the service to the viewer's default and returns 204", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    # A fresh account stores nil = "inherit the installation default" and
    # still resolves to Google (Vutuv.Maps via Vutuv.Prefs).
    assert Repo.get(User, user.id).default_map_service == nil
    assert Vutuv.Maps.default_service(user) == :google

    conn = post(conn, ~p"/maps/default", service: "apple")

    assert response(conn, 204)
    assert Repo.get(User, user.id).default_map_service == "apple"
  end

  test "an unknown service is rejected and leaves the default untouched", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    conn = post(conn, ~p"/maps/default", service: "bing")

    # The endpoint is fire-and-forget (the link still opened), so it still 204s;
    # the invalid value is simply never written (still nil = inherit).
    assert response(conn, 204)
    assert Repo.get(User, user.id).default_map_service == nil
  end

  test "a logged-out visitor cannot promote a default (404)", %{conn: conn} do
    assert conn |> post(~p"/maps/default", service: "apple") |> response(404)
  end
end
