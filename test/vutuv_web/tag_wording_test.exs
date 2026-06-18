defmodule VutuvWeb.TagWordingTest do
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Vutuv.Factory

  # The feature is called "tag" everywhere: the tables are tags/user_tags, the
  # URLs are /tags, the search operator is tag:. The UI used to say "skill"
  # (German "Fähigkeit"), which was both inconsistent with the operator and
  # semantically too narrow (tags also cover interests and topics). These tests
  # pin the wording so "skill" doesn't creep back into the UI.

  describe "profile tag section" do
    test "is headed Tags, not Skills", %{conn: conn} do
      user = insert(:activated_user)
      insert(:user_tag, user: user, tag: insert(:tag))

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ ~r{<h2[^>]*>\s*Tags\s*</h2>}
      refute html =~ "endorsements"
      refute html =~ ~r/skill/i
    end

    test "says Tag in German, not Fähigkeit", %{conn: conn} do
      user = insert(:activated_user)
      insert(:user_tag, user: user, tag: insert(:tag))

      html =
        conn
        |> put_req_header("accept-language", "de")
        |> get(~p"/#{user}")
        |> html_response(200)

      assert html =~ ~r{<h2[^>]*>\s*Tags\s*</h2>}
      refute html =~ "Empfehlungen"
      refute html =~ "Fähigkeit"
    end

    test "the owner's empty card invites adding a tag", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "Add a tag"
      refute html =~ ~r/skill/i
    end
  end

  describe "search" do
    test "speaks of tags, not skills", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/search")

      assert html =~ "Search for people, tags, or posts"
      refute html =~ ~r/skill/i
    end
  end
end
