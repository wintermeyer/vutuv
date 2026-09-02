defmodule VutuvWeb.ControllerHelpersTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts.User
  alias VutuvWeb.ControllerHelpers

  describe "safe_return_to/1" do
    test "keeps a same-origin absolute path" do
      assert ControllerHelpers.safe_return_to("/feed") == "/feed"
      assert ControllerHelpers.safe_return_to("/ch_alice/posts") == "/ch_alice/posts"
    end

    test "keeps the bare root path without raising" do
      # The old report_controller version sliced the string and raised
      # ArgumentError on "/" (binary_part("", 0, 1)). It must return "/".
      assert ControllerHelpers.safe_return_to("/") == "/"
    end

    test "rejects protocol-relative (external) URLs" do
      assert ControllerHelpers.safe_return_to("//evil.com") == nil
      assert ControllerHelpers.safe_return_to("//evil.com/path") == nil
    end

    test "rejects absolute URLs and anything that is not a local path" do
      assert ControllerHelpers.safe_return_to("https://evil.com") == nil
      assert ControllerHelpers.safe_return_to("evil.com") == nil
      assert ControllerHelpers.safe_return_to("") == nil
      assert ControllerHelpers.safe_return_to(nil) == nil
    end

    # A backslash is a slash to the WHATWG URL parser on an http(s) document, so
    # every current browser reads this as the host `evil.com` — while a check
    # that only knows about `//` reads it as a path here and hands it to an href.
    test "rejects a backslash where the second slash would go" do
      assert ControllerHelpers.safe_return_to("/\\evil.com") == nil
      assert ControllerHelpers.safe_return_to("/\\\\evil.com") == nil
      assert ControllerHelpers.safe_return_to("/feed\\evil.com") == nil
    end

    # The browser deletes these before it parses, so the string a check reads is
    # not the string that gets resolved: this one becomes `//evil.com`.
    test "rejects the characters a browser strips out of a URL" do
      assert ControllerHelpers.safe_return_to("/\t/evil.com") == nil
      assert ControllerHelpers.safe_return_to("/\n/evil.com") == nil
      assert ControllerHelpers.safe_return_to("/\r/evil.com") == nil
      assert ControllerHelpers.safe_return_to("/%09/evil.com") == nil
    end

    test "keeps an ordinary path with a query and a fragment" do
      assert ControllerHelpers.safe_return_to("/feed?type=replies") == "/feed?type=replies"
      assert ControllerHelpers.safe_return_to("/ch_alice/posts#x") == "/ch_alice/posts#x"
    end

    # The admin pages must not be left at all, so they pass their own prefix
    # rather than repeating the rule. The shape to refuse moves with it.
    test "a prefix narrows what counts as local" do
      assert ControllerHelpers.safe_return_to("/admin/accounts", "/admin/") == "/admin/accounts"
      assert ControllerHelpers.safe_return_to("/feed", "/admin/") == nil
      assert ControllerHelpers.safe_return_to("/admin//evil.com", "/admin/") == nil
      assert ControllerHelpers.safe_return_to("/admin/\\evil.com", "/admin/") == nil
    end
  end

  describe "referrer_url/2" do
    # A header is as caller-supplied as a query parameter, and this path used to
    # be handed to `redirect(to:)` with no check at all.
    test "falls back rather than returning a referer's off-origin path" do
      conn = build_conn() |> Plug.Conn.put_req_header("referer", "https://evil.example//x")

      assert ControllerHelpers.referrer_url(conn, "/feed") == "/feed"
    end

    test "keeps an ordinary referer path" do
      conn = build_conn() |> Plug.Conn.put_req_header("referer", "https://vutuv.de/ch_alice")

      assert ControllerHelpers.referrer_url(conn, "/feed") == "/ch_alice"
    end
  end

  describe "referrer_or_profile/2" do
    test "uses the referer path when present" do
      conn = build_conn() |> Plug.Conn.put_req_header("referer", "https://vutuv.de/feed")
      assert ControllerHelpers.referrer_or_profile(conn, nil) == "/feed"
    end

    test "falls back to the user's profile without a referer" do
      conn = build_conn()
      user = %User{username: "ch_alice"}
      assert ControllerHelpers.referrer_or_profile(conn, user) == "/ch_alice"
    end

    test "falls back to the landing page when logged out and refererless" do
      assert ControllerHelpers.referrer_or_profile(build_conn(), nil) == "/"
    end
  end
end
