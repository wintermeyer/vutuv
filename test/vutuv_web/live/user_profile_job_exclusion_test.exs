defmodule VutuvWeb.UserProfileJobExclusionTest do
  @moduledoc """
  The job-search viewer-exclusion list (issue #938) as seen on the profile
  (`VutuvWeb.UserProfileLive`): an excluded member — or a viewer at an excluded
  email domain — sees neither the availability badge nor the salary line, even
  when the owner set them to "Everyone". And adding a viewer to the list drops
  the badge on their open profile with no reload (PubSub).
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Activity

  # An owner broadcasting both job-search fields to everyone.
  defp job_owner do
    insert_activated_user(
      employment_status: "looking",
      employment_status_visibility: "everyone",
      desired_salary_min: 60_000,
      desired_salary_visibility: "everyone"
    )
  end

  test "a non-excluded viewer sees the availability badge and salary line", %{conn: conn} do
    {conn, _viewer} = create_and_login_user(conn)
    owner = job_owner()

    {:ok, view, html} = live(conn, ~p"/#{owner}")

    assert has_element?(view, "[data-employment-status]")
    assert html =~ "Salary expectation"
  end

  test "an excluded member sees neither field", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    owner = job_owner()
    insert(:viewer_exclusion, user: owner, excluded_user: viewer, domain: nil)

    {:ok, view, html} = live(conn, ~p"/#{owner}")

    refute has_element?(view, "[data-employment-status]")
    refute html =~ "Salary expectation"
  end

  test "a viewer whose confirmed email is at an excluded domain sees neither field", %{conn: conn} do
    attrs = %{
      "emails" => %{"0" => %{"value" => "me@acme.example"}},
      "first_name" => "Colleague",
      "tag_list" => @registration_tags
    }

    {conn, _viewer} = create_and_login_user(conn, attrs)
    owner = job_owner()
    insert(:viewer_exclusion, user: owner, domain: "acme.example")

    {:ok, view, html} = live(conn, ~p"/#{owner}")

    refute has_element?(view, "[data-employment-status]")
    refute html =~ "Salary expectation"
  end

  test "adding a viewer to the list drops the badge live, no reload", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    owner = job_owner()

    {:ok, view, _html} = live(conn, ~p"/#{owner}")
    assert has_element?(view, "[data-employment-status]")

    # The owner excludes this viewer from another place, then broadcasts the
    # change on their Activity topic (what the editor does).
    insert(:viewer_exclusion, user: owner, excluded_user: viewer, domain: nil)
    Activity.broadcast(owner.id, {:job_search_visibility_changed, %{}})

    refute has_element?(view, "[data-employment-status]")
    refute render(view) =~ "Salary expectation"
  end

  test "a viewer at a SUBDOMAIN of an excluded domain sees neither field", %{conn: conn} do
    attrs = %{
      "emails" => %{"0" => %{"value" => "recruiter@eu.mail.acme.example"}},
      "first_name" => "Sub",
      "tag_list" => @registration_tags
    }

    {conn, _viewer} = create_and_login_user(conn, attrs)
    owner = job_owner()
    insert(:viewer_exclusion, user: owner, domain: "acme.example")

    {:ok, view, html} = live(conn, ~p"/#{owner}")

    refute has_element?(view, "[data-employment-status]")
    refute html =~ "Salary expectation"
  end

  test "a viewer the owner has BLOCKED sees neither field, with no list entry", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    owner = job_owner()
    {:ok, _} = Vutuv.Social.block_user(owner, viewer)

    {:ok, view, html} = live(conn, ~p"/#{owner}")

    refute has_element?(view, "[data-employment-status]")
    refute html =~ "Salary expectation"
  end
end
