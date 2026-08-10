defmodule VutuvWeb.ActingAsOrganizationTest do
  @moduledoc """
  Switching into an organization for a session (issue #1335).

  The security half is the point of most of these: the session's
  `acting_as_organization_id` is signed but not encrypted and valid for days, so
  it is re-authorized on **every** request and **every** socket mount rather than
  trusted — the trap #1034 and #1036 already cost this app twice.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.AccountEvents
  alias Vutuv.Organizations
  alias Vutuv.Posts

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp switched_in(conn) do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

    conn = post(conn, ~p"/organizations/#{organization.slug}/act_as")
    %{conn: recycle_login(conn), owner: owner, organization: organization}
  end

  # Carries the session (and its acting-as value) into the next request the way
  # a browser does.
  defp recycle_login(conn),
    do: conn |> recycle() |> Map.put(:secret_key_base, conn.secret_key_base)

  describe "switching in" do
    test "a publisher may, and the chrome says so unmistakably", %{conn: conn} do
      %{conn: conn, organization: organization} = switched_in(conn)

      html = conn |> get(~p"/feed") |> html_response(200)

      assert html =~ "acting-as-banner"
      assert html =~ organization.name
      # Leaving is reachable from wherever the banner is.
      assert html =~ "stop-acting-as"
    end

    test "a member without the publisher role cannot", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      organization = active_organization_for(owner)

      # An owner who never granted themselves publisher is not a publisher.
      conn |> post(~p"/organizations/#{organization.slug}/act_as") |> response(404)
    end

    test "both directions are logged, naming the organization", %{conn: conn} do
      %{conn: conn, owner: owner, organization: organization} = switched_in(conn)

      conn |> delete(~p"/system/act_as") |> response(302)

      events = AccountEvents.page(owner, %{})
      kinds = Enum.map(events, & &1.kind)
      assert "acted_as_organization" in kinds
      assert "stopped_acting_as_organization" in kinds

      event = Enum.find(events, &(&1.kind == "acted_as_organization"))
      assert event.details["organization"] == organization.name
    end
  end

  describe "the mode is re-authorized, never trusted" do
    test "a withdrawn publisher role ends the mode on the next request", %{conn: conn} do
      %{conn: conn, owner: owner, organization: organization} = switched_in(conn)

      # Still in the mode …
      assert conn |> get(~p"/feed") |> html_response(200) =~ "acting-as-banner"

      # … and the moment the role goes, the very next request is themselves
      # again — not at the next login. The session still carries the id. Only
      # the publisher role is withdrawn: they are the page's only owner, and
      # the last-owner guard rightly refuses to strip that one.
      {:ok, ["owner"]} = Organizations.set_roles(organization, owner, ["owner"], owner)

      refute conn |> recycle_login() |> get(~p"/feed") |> html_response(200) =~ "acting-as-banner"
    end

    test "posting in the organization's name stops working at once too", %{conn: conn} do
      %{owner: owner, organization: organization} = switched_in(conn)

      assert {:ok, _} = Posts.create_organization_post(organization, owner, %{body: "Ours."})

      {:ok, ["owner"]} = Organizations.set_roles(organization, owner, ["owner"], owner)

      # The context re-checks rather than trusting whatever the session says.
      assert {:error, :forbidden} =
               Posts.create_organization_post(organization, owner, %{body: "Still ours?"})
    end
  end

  describe "leaving" do
    test "one click, and the member is themselves again", %{conn: conn} do
      %{conn: conn} = switched_in(conn)

      conn = delete(conn, ~p"/system/act_as", %{"return_to" => "/feed"})
      assert redirected_to(conn) == "/feed"

      refute conn |> recycle_login() |> get(~p"/feed") |> html_response(200) =~ "acting-as-banner"
    end

    test "an absolute return_to is refused — this control is on every page", %{conn: conn} do
      %{conn: conn} = switched_in(conn)

      conn = delete(conn, ~p"/system/act_as", %{"return_to" => "https://example.com/"})
      assert redirected_to(conn) == "/feed"

      conn =
        conn |> recycle_login() |> delete(~p"/system/act_as", %{"return_to" => "//example.com/"})

      assert redirected_to(conn) == "/feed"
    end
  end

  describe "the feed composer" do
    test "names the organization on the button and publishes in its name", %{conn: conn} do
      %{conn: conn, owner: owner, organization: organization} = switched_in(conn)

      {:ok, view, html} = live(conn, ~p"/feed")

      # The last thing seen before publishing is whose name goes on it.
      assert html =~ organization.name

      view |> element("#open-composer") |> render_click()

      view
      |> form("#composer-form", %{"post" => %{"body" => "Aus dem Haus."}})
      |> render_submit()

      [post] = Posts.organization_posts_page(organization, owner).entries
      assert post.body == "Aus dem Haus."
      assert post.acting_user_id == owner.id
    end
  end
end
