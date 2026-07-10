defmodule VutuvWeb.JobSearchExclusionsLiveTest do
  @moduledoc """
  The job-search viewer-exclusion editor (/settings/job_search_exclusions,
  issue #938): add members by @handle and email domains, remove rows, all over
  the socket, each change broadcasting on the owner's Activity topic so an open
  profile updates too.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Accounts
  alias Vutuv.Activity

  test "redirects anonymous visitors", %{conn: conn} do
    conn = get(conn, ~p"/settings/job_search_exclusions")
    assert redirected_to(conn) == ~p"/"
  end

  describe "the editor" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/settings/job_search_exclusions")
      %{live: live, user: user}
    end

    test "excludes a member by @handle and lists them", %{live: live, user: user} do
      boss = insert(:activated_user, username: "the-boss", first_name: "Bossy")

      html =
        live
        |> form("#exclude-member-form", member: %{handle: "@the-boss"})
        |> render_submit()

      assert html =~ "@the-boss"
      assert has_element?(live, "#exclusion-list")
      assert [%{excluded_user_id: id}] = Accounts.list_viewer_exclusions(user)
      assert id == boss.id
    end

    test "shows a clear error for an unknown handle and for self", %{live: live, user: user} do
      html =
        live
        |> form("#exclude-member-form", member: %{handle: "nobody"})
        |> render_submit()

      assert html =~ "No member has that @handle"
      assert Accounts.viewer_exclusion_count(user) == 0

      html =
        live
        |> form("#exclude-member-form", member: %{handle: user.username})
        |> render_submit()

      assert html =~ "cannot exclude yourself"
    end

    test "excludes a normalized email domain and rejects a bad one", %{live: live, user: user} do
      html =
        live
        |> form("#exclude-domain-form", domain: %{domain: "HTTPS://Employer.example/jobs"})
        |> render_submit()

      assert html =~ "employer.example"
      assert [%{domain: "employer.example"}] = Accounts.list_viewer_exclusions(user)

      html =
        live
        |> form("#exclude-domain-form", domain: %{domain: "not a domain"})
        |> render_submit()

      assert html =~ "must be a domain"
    end

    test "removes a row over the socket", %{live: live, user: user} do
      live |> form("#exclude-domain-form", domain: %{domain: "gone.example"}) |> render_submit()
      assert [x] = Accounts.list_viewer_exclusions(user)
      assert has_element?(live, "#exclusion-#{x.id}")

      live |> element("#exclusion-#{x.id} button", "Remove") |> render_click()

      refute has_element?(live, "#exclusion-#{x.id}")
      assert Accounts.viewer_exclusion_count(user) == 0
    end

    test "broadcasts on the owner's topic so an open profile can update", %{
      live: live,
      user: user
    } do
      Activity.subscribe(user.id)
      insert(:activated_user, username: "a-colleague")

      live
      |> form("#exclude-member-form", member: %{handle: "a-colleague"})
      |> render_submit()

      assert_receive {:job_search_visibility_changed, _}
    end
  end
end
