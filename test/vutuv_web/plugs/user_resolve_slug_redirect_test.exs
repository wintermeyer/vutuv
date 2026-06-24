defmodule VutuvWeb.Plug.UserResolveSlugRedirectTest do
  @moduledoc """
  A retired legacy handle (the dotted / over-length imports, preserved in
  `users.legacy_username`) 301s to the member's current handle - across the
  profile, its sub-pages and the agent-format siblings - while a live handle
  always wins over a stale legacy handle.
  """
  use VutuvWeb.ConnCase

  setup do
    user =
      insert_activated_user(
        username: "oliver_gassner",
        legacy_username: "oliver.gassner",
        first_name: "Oliver",
        last_name: "Gassner"
      )

    %{user: user}
  end

  test "301s an old dotted profile URL to the current handle", %{conn: conn} do
    conn = get(conn, "/oliver.gassner")
    assert redirected_to(conn, 301) == "/oliver_gassner"
  end

  test "keeps the agent-format extension on the redirect", %{conn: conn} do
    conn = get(conn, "/oliver.gassner.md")
    assert redirected_to(conn, 301) == "/oliver_gassner.md"
  end

  test "redirects a profile sub-page too", %{conn: conn} do
    conn = get(conn, "/oliver.gassner/emails")
    assert redirected_to(conn, 301) == "/oliver_gassner/emails"
  end

  test "carries the query string", %{conn: conn} do
    conn = get(conn, "/oliver.gassner?lang=de")
    assert redirected_to(conn, 301) == "/oliver_gassner?lang=de"
  end

  test "a live handle always wins over a stale legacy handle", %{conn: conn} do
    live = insert_activated_user(username: "live_handle", first_name: "Live", last_name: "One")
    insert_activated_user(username: "someone_else", legacy_username: "live_handle")

    conn = get(conn, "/live_handle")

    assert html_response(conn, 200) =~ live.first_name
  end

  test "an unknown handle still 404s, never a redirect", %{conn: conn} do
    conn = get(conn, "/nope.nope")
    assert conn.status == 404
  end
end
