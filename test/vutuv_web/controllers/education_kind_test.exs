defmodule VutuvWeb.EducationKindTest do
  @moduledoc """
  The CV categories on education entries (issue #849, the education twin of
  the work-experience categories from #840): a member files each entry as
  higher education (Studium), vocational training (Berufsausbildung) or
  school education (Schulbildung), and every list rendering groups the
  entries under labeled headings — but only once a non-university entry
  exists, so the common degrees-only profile keeps its familiar single list.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Profiles.Education

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{conn: conn, user: user}
  end

  defp insert_education(user, attrs) do
    insert(:education, Keyword.merge([user: user], attrs))
  end

  describe "the form" do
    test "new renders a category picker posting to the settings route", %{conn: conn} do
      html = conn |> get(~p"/settings/educations/new") |> html_response(200)

      assert html =~ ~s(action="/settings/educations")
      assert html =~ ~s(<select id="education_kind" name="education[kind]")
      assert html =~ ~s(value="university")
      assert html =~ ~s(value="apprenticeship")
      assert html =~ ~s(value="school")
    end

    test "create persists the chosen category", %{conn: conn, user: user} do
      params = %{"school" => "Gymnasium Musterstadt", "degree" => "Abitur", "kind" => "school"}

      conn = post(conn, ~p"/settings/educations", %{"education" => params})
      assert redirected_to(conn) == ~p"/settings/educations"

      assert [%{kind: "school"}] = Repo.all(Ecto.assoc(user, :educations))
    end

    test "update moves an entry into another category", %{conn: conn, user: user} do
      edu = insert_education(user, school: "IHK Koblenz", degree: "Fachinformatiker")

      edit_html = conn |> get(~p"/settings/educations/#{edu}/edit") |> html_response(200)
      assert edit_html =~ ~s(action="/settings/educations/#{edu.slug}")

      conn =
        put(conn, ~p"/settings/educations/#{edu}", %{
          "education" => %{"kind" => "apprenticeship"}
        })

      assert redirected_to(conn) == ~p"/settings/educations"
      assert Repo.get!(Education, edu.id).kind == "apprenticeship"
    end
  end

  describe "the public section page" do
    test "groups entries under category headings once a non-university entry exists",
         %{conn: conn, user: user} do
      insert_education(user, school: "MIT", degree: "BSc")
      insert_education(user, school: "IHK Koblenz", degree: "Azubi", kind: "apprenticeship")
      insert_education(user, school: "Gymnasium Musterstadt", degree: "Abitur", kind: "school")

      html = conn |> get(~p"/#{user}/educations") |> html_response(200)

      assert html =~ "Higher Education"
      assert html =~ "Vocational Training"
      assert html =~ "School Education"
    end

    test "a degrees-only member keeps the single unlabeled list", %{conn: conn, user: user} do
      insert_education(user, school: "MIT", degree: "BSc")

      html = conn |> get(~p"/#{user}/educations") |> html_response(200)

      refute html =~ "Higher Education"
      refute html =~ "Vocational Training"
      refute html =~ "School Education"
    end

    test "the owner's editor groups the same way", %{conn: conn, user: user} do
      insert_education(user, school: "MIT", degree: "BSc")
      insert_education(user, school: "Gymnasium Musterstadt", kind: "school")

      html = conn |> get(~p"/settings/educations") |> html_response(200)

      assert html =~ "Higher Education"
      assert html =~ "School Education"
    end
  end

  describe "the entry show page" do
    test "names the category", %{conn: conn, user: user} do
      edu = insert_education(user, school: "IHK Koblenz", kind: "apprenticeship")

      html = conn |> get(~p"/#{user}/educations/#{edu}") |> html_response(200)

      assert html =~ "Category"
      assert html =~ "Vocational Training"
    end
  end

  describe "the profile page" do
    test "the Education card groups its preview under the same headings",
         %{conn: conn, user: user} do
      insert_education(user, school: "MIT", degree: "BSc")
      insert_education(user, school: "Gymnasium Musterstadt", kind: "school")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "Higher Education"
      assert html =~ "School Education"
    end

    test "a degrees-only profile card shows no category headings", %{conn: conn, user: user} do
      insert_education(user, school: "MIT", degree: "BSc")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      refute html =~ "Higher Education"
      refute html =~ "School Education"
    end
  end
end
