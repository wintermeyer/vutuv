defmodule VutuvWeb.JsonLdXssTest do
  use VutuvWeb.ConnCase, async: true

  # The public profile page embeds a JSON-LD BreadcrumbList in a
  # <script type="application/ld+json"> tag that interpolates the user's name.
  # Jason's default encoder escapes quotes but NOT the forward slash, so a name
  # containing "</script>" would close the script element early and let the rest
  # execute as HTML: stored XSS on a public profile. The fix is to encode every
  # JSON-LD block with `escape: :html_safe`, which escapes "<", ">" and "&" as
  # < / > / & so the payload can never break out of the tag.

  setup %{conn: conn} do
    payload = "</script><script>alert(1)</script>"

    user =
      insert(:user, validated?: true, first_name: "Eve", last_name: payload)

    insert(:slug, value: user.active_slug, disabled: false, user: user)

    {:ok, conn: conn, user: user, payload: payload}
  end

  test "a malicious name cannot break out of the JSON-LD script tag",
       %{conn: conn, user: user, payload: payload} do
    conn = get(conn, ~p"/users/#{user}")
    body = html_response(conn, 200)

    # The raw closing-tag injection must never appear literally in the markup.
    refute body =~ payload
    refute body =~ "</script><script>"

    # The name is still present, but the "<" that would close the tag is
    # escaped to its < unicode form inside the JSON-LD block, so the
    # payload can never break out of the <script> element.
    assert body =~ "\\u003C\\/script>\\u003Cscript>alert(1)\\u003C\\/script>"
  end
end
