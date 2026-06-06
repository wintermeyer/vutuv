defmodule VutuvWeb.Plug.EnsureValidatedTest do
  use VutuvWeb.ConnCase, async: true

  # Regression: the error plugs rendered VutuvWeb.ErrorView, which no longer
  # exists under Phoenix 1.8 (it is VutuvWeb.ErrorHTML), so the 404 path
  # raised instead of returning a 404. An unvalidated user's profile goes
  # through EnsureValidated and must return a clean 404.
  test "an unvalidated user's profile returns 404, not a crash" do
    user = insert(:user, active_slug: "unvalidated-user", validated?: false)
    insert(:slug, value: "unvalidated-user", user: user, disabled: false)

    conn = get(build_conn(), "/unvalidated-user")

    assert conn.status == 404
    assert conn.resp_body =~ ~r/not found/i
  end
end
