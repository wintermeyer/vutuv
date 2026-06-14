defmodule VutuvWeb.ControllerHelpersTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts.User
  alias VutuvWeb.ControllerHelpers

  describe "safe_return_to/1" do
    test "keeps a same-origin absolute path" do
      assert ControllerHelpers.safe_return_to("/feed") == "/feed"
      assert ControllerHelpers.safe_return_to("/alice/posts") == "/alice/posts"
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
  end

  describe "referrer_or_profile/2" do
    test "uses the referer path when present" do
      conn = build_conn() |> Plug.Conn.put_req_header("referer", "https://vutuv.de/feed")
      assert ControllerHelpers.referrer_or_profile(conn, nil) == "/feed"
    end

    test "falls back to the user's profile without a referer" do
      conn = build_conn()
      user = %User{active_slug: "alice"}
      assert ControllerHelpers.referrer_or_profile(conn, user) == "/alice"
    end

    test "falls back to the landing page when logged out and refererless" do
      assert ControllerHelpers.referrer_or_profile(build_conn(), nil) == "/"
    end
  end
end
