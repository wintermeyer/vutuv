defmodule VutuvWeb.JobExclusionsLiveTest do
  @moduledoc """
  The per-posting and organization-default exclusion editors (issue #939): add
  members / organizations / email domains and remove them over the socket,
  owner/role-holder gated.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Jobs
  alias Vutuv.Jobs.Exclusions

  describe "per-posting editor" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, posting} = Jobs.create_draft(user, %{"title" => "Backend Engineer (m/w/d)"})
      {:ok, live, _html} = live(conn, ~p"/jobs/#{posting.slug}/exclusions")
      %{live: live, user: user, posting: posting}
    end

    test "excludes a member by @handle and lists them", %{live: live, posting: posting} do
      insert(:activated_user, username: "the-rival", first_name: "Riva")

      html =
        live
        |> form("#exclude-member-form", member: %{handle: "@the-rival"})
        |> render_submit()

      assert html =~ "@the-rival"
      assert [%{excluded_user: %{username: "the-rival"}}] = Exclusions.list_for_posting(posting)
    end

    test "excludes an organization by slug", %{live: live, posting: posting} do
      org = insert(:organization, name: "Rival GmbH")

      html =
        live
        |> form("#exclude-organization-form", organization: %{handle: org.slug})
        |> render_submit()

      assert html =~ "Rival GmbH"
      assert [%{excluded_organization: %{id: id}}] = Exclusions.list_for_posting(posting)
      assert id == org.id
    end

    test "excludes a normalized email domain and rejects a bad one", %{
      live: live,
      posting: posting
    } do
      html =
        live
        |> form("#exclude-domain-form", domain: %{domain: "HTTPS://Rival.example/careers"})
        |> render_submit()

      assert html =~ "rival.example"
      assert [%{domain: "rival.example"}] = Exclusions.list_for_posting(posting)

      html =
        live
        |> form("#exclude-domain-form", domain: %{domain: "not a domain"})
        |> render_submit()

      assert html =~ "must be a domain"
    end

    test "shows a clear error for an unknown handle and for the poster", %{
      live: live,
      user: user
    } do
      html =
        live |> form("#exclude-member-form", member: %{handle: "nobody-here"}) |> render_submit()

      assert html =~ "No member has that @handle"

      html =
        live |> form("#exclude-member-form", member: %{handle: user.username}) |> render_submit()

      assert html =~ "cannot exclude yourself"
    end

    test "removes a row over the socket", %{live: live, posting: posting} do
      live |> form("#exclude-domain-form", domain: %{domain: "gone.example"}) |> render_submit()
      assert [row] = Exclusions.list_for_posting(posting)
      assert has_element?(live, "#exclusion-#{row.id}")

      live |> element("#exclusion-#{row.id} button", "Remove") |> render_click()

      refute has_element?(live, "#exclusion-#{row.id}")
      assert Exclusions.list_for_posting(posting) == []
    end
  end

  test "a non-owner cannot open the per-posting editor", %{conn: conn} do
    posting = Vutuv.JobsHelpers.publish_job!()
    {conn, _stranger} = create_and_login_user(conn)

    assert {:error, {:live_redirect, %{to: "/jobs/mine"}}} =
             live(conn, ~p"/jobs/#{posting.slug}/exclusions")
  end

  describe "organization-default editor" do
    setup %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      org = insert(:organization, created_by_user_id: owner.id)
      {:ok, live, _html} = live(conn, ~p"/organizations/#{org.slug}/exclusions")
      %{live: live, owner: owner, org: org}
    end

    test "shows the Job exclusions tab", %{live: live, org: org} do
      assert has_element?(live, "a[href='/organizations/#{org.slug}/exclusions']")
    end

    test "adds a standing domain exclusion", %{live: live, org: org} do
      html =
        live
        |> form("#exclude-domain-form", domain: %{domain: "competitor.example"})
        |> render_submit()

      assert html =~ "competitor.example"
      assert [%{domain: "competitor.example"}] = Exclusions.list_for_organization(org)
    end

    test "cannot exclude itself", %{live: live, org: org} do
      html =
        live
        |> form("#exclude-organization-form", organization: %{handle: org.slug})
        |> render_submit()

      assert html =~ "cannot exclude itself"
      assert Exclusions.list_for_organization(org) == []
    end
  end

  test "a logged-in non-member cannot open the organization exclusions page", %{conn: conn} do
    owner = insert(:activated_user)
    org = insert(:organization, created_by_user_id: owner.id)
    {stranger_conn, _stranger} = create_and_login_user(conn)

    assert stranger_conn |> get(~p"/organizations/#{org.slug}/exclusions") |> response(404)
  end
end
