defmodule VutuvWeb.WorkExperienceCompanyLinkTest do
  @moduledoc """
  Linking a work experience to a verified company page from the editor
  (issue #931): the JSON suggestion endpoint, the hidden company_id field on the
  form, and that create/update persist and clear the link.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{conn: conn, user: user}
  end

  describe "company_suggestions" do
    test "returns the matching verified company as JSON", %{conn: conn} do
      company = insert(:company, name: "Acme GmbH")

      body =
        conn
        |> get(~p"/settings/work_experiences/company_suggestions", q: "acme gmbh")
        |> json_response(200)

      assert body["company"]["id"] == company.id
      assert body["company"]["name"] == "Acme GmbH"
      assert body["company"]["path"] == "/companies/#{company.slug}"
    end

    test "returns null when nothing matches", %{conn: conn} do
      body =
        conn
        |> get(~p"/settings/work_experiences/company_suggestions", q: "nobody here")
        |> json_response(200)

      assert body["company"] == nil
    end
  end

  describe "the form" do
    test "new renders the quiet company-link box with the hidden field", %{conn: conn} do
      html = conn |> get(~p"/settings/work_experiences/new") |> html_response(200)

      assert html =~ "data-company-link"
      assert html =~ ~s(name="work_experience[company_id]")
    end

    test "edit seeds the linked company for a linked experience", %{conn: conn, user: user} do
      company = insert(:company, name: "Span AG")
      work = insert(:work_experience, user: user, company: company)

      html = conn |> get(~p"/settings/work_experiences/#{work}/edit") |> html_response(200)

      assert html =~ ~s(data-linked-name="Span AG")
      assert html =~ ~s(data-linked-id="#{company.id}")
    end
  end

  describe "create and update" do
    test "create persists the link", %{conn: conn, user: user} do
      company = insert(:company)

      conn =
        post(conn, ~p"/settings/work_experiences", %{
          "work_experience" => %{
            "organization" => "Acme",
            "title" => "Engineer",
            "kind" => "employment",
            "company_id" => company.id
          }
        })

      assert redirected_to(conn) == ~p"/settings/work_experiences"
      work = Repo.get_by!(WorkExperience, user_id: user.id)
      assert work.company_id == company.id
    end

    test "update clears the link when company_id is blank", %{conn: conn, user: user} do
      company = insert(:company)
      work = insert(:work_experience, user: user, company: company)

      conn =
        put(conn, ~p"/settings/work_experiences/#{work}", %{
          "work_experience" => %{
            "organization" => work.organization,
            "title" => work.title,
            "kind" => "employment",
            "company_id" => ""
          }
        })

      assert redirected_to(conn) == ~p"/settings/work_experiences"
      assert is_nil(Repo.reload!(work).company_id)
    end
  end
end
