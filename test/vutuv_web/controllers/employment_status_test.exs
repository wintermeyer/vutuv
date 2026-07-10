defmodule VutuvWeb.EmploymentStatusTest do
  @moduledoc """
  The employment-status feature: the job-availability badge on the profile
  header and the select that sets it on the Basics & photos form (issue #870),
  plus who may see the badge (issue #928 — everyone / signed-in members /
  nobody, default members).
  """

  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Repo

  describe "the profile badge" do
    # These render checks pin the wording/position, so the member opts the badge
    # public ("everyone") to keep it visible to the logged-out test conn; the
    # viewer-scoping rules get their own describe block below.
    test "shows 'Looking for a job' for a member who is looking", %{conn: conn} do
      user =
        insert_activated_user(
          employment_status: "looking",
          employment_status_visibility: "everyone"
        )

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "Looking for a job"
      assert html =~ ~s(data-employment-status="looking")
    end

    test "shows 'Open to offers' for a member who is open", %{conn: conn} do
      user =
        insert_activated_user(employment_status: "open", employment_status_visibility: "everyone")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "Open to offers"
      assert html =~ ~s(data-employment-status="open")
    end

    test "renders the badge above the tagline, right below the name", %{conn: conn} do
      user =
        insert_activated_user(
          employment_status: "looking",
          employment_status_visibility: "everyone",
          headline: "Some tagline here"
        )

      html = conn |> get(~p"/#{user}") |> html_response(200)

      # The pill sits on its own line under the name, ahead of the tagline text.
      badge_at = :binary.match(html, "data-employment-status") |> elem(0)
      tagline_at = :binary.match(html, "Some tagline here") |> elem(0)
      assert badge_at < tagline_at
    end

    test "shows no badge for a member who has not set a status", %{conn: conn} do
      user = insert_activated_user(employment_status: nil, headline: "Just here")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      refute html =~ "data-employment-status"
      refute html =~ "Looking for a job"
      refute html =~ "Open to offers"
    end
  end

  describe "badge visibility scoping (issue #928)" do
    test "the default (members) hides the badge from a logged-out visitor", %{conn: conn} do
      user = insert_activated_user(employment_status: "looking")
      assert user.employment_status_visibility == "members"

      html = conn |> get(~p"/#{user}") |> html_response(200)

      refute html =~ "data-employment-status"
      refute html =~ "Looking for a job"
    end

    test "the default (members) shows the badge to a signed-in member", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      user = insert_activated_user(employment_status: "looking")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "Looking for a job"
    end

    test "everyone shows the badge to a logged-out visitor", %{conn: conn} do
      user =
        insert_activated_user(employment_status: "open", employment_status_visibility: "everyone")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "Open to offers"
    end

    test "hidden shows the badge to nobody, member or not", %{conn: conn} do
      user =
        insert_activated_user(
          employment_status: "looking",
          employment_status_visibility: "hidden"
        )

      logged_out = conn |> get(~p"/#{user}") |> html_response(200)
      refute logged_out =~ "Looking for a job"

      {member_conn, _viewer} = create_and_login_user(conn)
      member_view = member_conn |> get(~p"/#{user}") |> html_response(200)
      refute member_view =~ "Looking for a job"
    end

    test "the owner sees their own members-scoped badge but not a hidden one", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, _} = Accounts.update_user(user, %{"employment_status" => "looking"})
      members = conn |> get(~p"/#{user}") |> html_response(200)
      assert members =~ "Looking for a job"

      {:ok, _} = Accounts.update_user(user, %{"employment_status_visibility" => "hidden"})
      hidden = conn |> get(~p"/#{user}") |> html_response(200)
      refute hidden =~ "Looking for a job"
    end
  end

  describe "agent formats follow the visibility rule (issue #928)" do
    test "an everyone status appears in the anonymous .md and .json", %{conn: conn} do
      user =
        insert_activated_user(
          employment_status: "looking",
          employment_status_visibility: "everyone"
        )

      md = conn |> get("/#{user.username}.md") |> response(200)
      assert md =~ "Looking for a job"

      json = conn |> get("/#{user.username}.json") |> response(200)
      assert Jason.decode!(json)["employment_status"] == "looking"
    end

    test "a members status is absent from the anonymous agent formats", %{conn: conn} do
      user =
        insert_activated_user(
          employment_status: "looking",
          employment_status_visibility: "members"
        )

      md = conn |> get("/#{user.username}.md") |> response(200)
      refute md =~ "Looking for a job"

      json = conn |> get("/#{user.username}.json") |> response(200)
      assert Jason.decode!(json)["employment_status"] == nil
    end

    test "a hidden status is absent from the anonymous agent formats", %{conn: conn} do
      user =
        insert_activated_user(employment_status: "open", employment_status_visibility: "hidden")

      json = conn |> get("/#{user.username}.json") |> response(200)
      assert Jason.decode!(json)["employment_status"] == nil
    end
  end

  describe "the Basics & photos form" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "renders the employment-status select with the three choices", %{conn: conn} do
      html = conn |> get(~p"/settings/profile") |> html_response(200)

      assert html =~ ~s(name="user[employment_status]")
      assert html =~ "Not open to work"
      assert html =~ "Open to offers"
      assert html =~ "Looking for a job"
    end

    test "the visibility select is present but hidden until a status is set", %{conn: conn} do
      html = conn |> get(~p"/settings/profile") |> html_response(200)

      assert html =~ ~s(name="user[employment_status_visibility]")
      # No status yet, so the sub-field ships hidden (no clutter).
      assert html =~ ~r/data-employment-visibility[^>]*class="[^"]*hidden/
    end

    test "the visibility select is revealed once a status is set", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_user(user, %{"employment_status" => "open"})

      html = conn |> get(~p"/settings/profile") |> html_response(200)

      assert html =~ ~s(name="user[employment_status_visibility]")
      refute html =~ ~r/data-employment-visibility[^>]*class="[^"]*hidden/
    end

    test "saving 'looking' persists the status", %{conn: conn, user: user} do
      conn = put(conn, ~p"/settings/profile", user: %{"employment_status" => "looking"})

      assert redirected_to(conn) == ~p"/#{user}"
      assert Repo.get!(User, user.id).employment_status == "looking"
    end

    test "saving a visibility choice persists it", %{conn: conn, user: user} do
      put(conn, ~p"/settings/profile",
        user: %{"employment_status" => "looking", "employment_status_visibility" => "everyone"}
      )

      reloaded = Repo.get!(User, user.id)
      assert reloaded.employment_status == "looking"
      assert reloaded.employment_status_visibility == "everyone"
    end

    test "the saved status then renders as a badge on the profile", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_user(user, %{"employment_status" => "open"})

      html = conn |> get(~p"/#{user}") |> html_response(200)
      assert html =~ "Open to offers"
    end

    test "choosing 'Not open to work' clears a previously set status", %{conn: conn, user: user} do
      {:ok, user} = Accounts.update_user(user, %{"employment_status" => "looking"})
      assert user.employment_status == "looking"

      put(conn, ~p"/settings/profile", user: %{"employment_status" => ""})

      assert Repo.get!(User, user.id).employment_status == nil
    end
  end
end
