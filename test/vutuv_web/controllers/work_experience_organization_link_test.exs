defmodule VutuvWeb.WorkExperienceOrganizationLinkTest do
  @moduledoc """
  Linking a work experience to a verified organization page from the editor
  (issue #931): the JSON suggestion endpoint, the hidden organization_id field on the
  form, and that create/update persist and clear the link.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{conn: conn, user: user}
  end

  describe "organization_suggestions" do
    test "returns the matching verified organization as JSON", %{conn: conn} do
      organization = insert(:organization, name: "Acme GmbH")

      body =
        conn
        |> get(~p"/settings/work_experiences/organization_suggestions", q: "acme gmbh")
        |> json_response(200)

      assert body["organization"]["id"] == organization.id
      assert body["organization"]["name"] == "Acme GmbH"
      assert body["organization"]["path"] == "/organizations/#{organization.slug}"
    end

    test "returns null when nothing matches", %{conn: conn} do
      body =
        conn
        |> get(~p"/settings/work_experiences/organization_suggestions", q: "nobody here")
        |> json_response(200)

      assert body["organization"] == nil
    end
  end

  describe "the form" do
    test "new renders the quiet organization-link box with the hidden field", %{conn: conn} do
      html = conn |> get(~p"/settings/work_experiences/new") |> html_response(200)

      assert html =~ "data-organization-link"
      assert html =~ ~s(name="work_experience[organization_id]")
    end

    test "edit seeds the linked organization for a linked experience", %{conn: conn, user: user} do
      organization = insert(:organization, name: "Span AG")
      work = insert(:work_experience, user: user, organization_page: organization)

      html = conn |> get(~p"/settings/work_experiences/#{work}/edit") |> html_response(200)

      assert html =~ ~s(data-linked-name="Span AG")
      assert html =~ ~s(data-linked-id="#{organization.id}")
    end
  end

  describe "create and update" do
    test "create persists the link", %{conn: conn, user: user} do
      organization = insert(:organization)

      conn =
        post(conn, ~p"/settings/work_experiences", %{
          "work_experience" => %{
            "organization" => "Acme",
            "title" => "Engineer",
            "kind" => "employment",
            "organization_id" => organization.id
          }
        })

      assert redirected_to(conn) == ~p"/settings/work_experiences"
      work = Repo.get_by!(WorkExperience, user_id: user.id)
      assert work.organization_id == organization.id
    end

    test "update clears the link when organization_id is blank", %{conn: conn, user: user} do
      organization = insert(:organization)
      work = insert(:work_experience, user: user, organization_page: organization)

      conn =
        put(conn, ~p"/settings/work_experiences/#{work}", %{
          "work_experience" => %{
            "organization" => work.organization,
            "title" => work.title,
            "kind" => "employment",
            "organization_id" => ""
          }
        })

      assert redirected_to(conn) == ~p"/settings/work_experiences"
      assert is_nil(Repo.reload!(work).organization_id)
    end
  end
end
