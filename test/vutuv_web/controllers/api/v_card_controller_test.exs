defmodule VutuvWeb.Api.VCardControllerTest do
  use VutuvWeb.ConnCase, async: true

  setup do
    user = insert(:user, active_slug: "vcard-tester", validated?: true)
    insert(:slug, value: "vcard-tester", user: user, disabled: false)
    %{user: user}
  end

  test "GET vcard returns a 200 text/vcard body" do
    conn = get(build_conn(), "/api/1.0/users/vcard-tester/vcard")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/vcard"
    assert conn.resp_body =~ "BEGIN:VCARD"
    assert conn.resp_body =~ "END:VCARD"
  end
end
