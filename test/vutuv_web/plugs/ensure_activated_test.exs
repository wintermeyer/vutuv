defmodule VutuvWeb.Plug.EnsureActivatedTest do
  use VutuvWeb.ConnCase, async: true

  # Regression: the error plugs rendered VutuvWeb.ErrorView, which no longer
  # exists under Phoenix 1.8 (it is VutuvWeb.ErrorHTML), so the 404 path
  # raised instead of returning a 404. An unactivated user's profile goes
  # through EnsureActivated and must return a clean 404.
  test "an unactivated user's profile returns 404, not a crash" do
    insert(:user, active_slug: "unactivated-user", email_confirmed?: false)

    conn = get(build_conn(), "/unactivated-user")

    assert conn.status == 404
    assert conn.resp_body =~ ~r/not found/i
  end
end
