defmodule VutuvWeb.WorkExperienceQualificationTest do
  @moduledoc """
  Linking a work experience to the credential it was earned with (issue #858):
  the ownership-scoped FK on the changeset, the conditional select on the job
  form, and the "With qualification" line on the public renderings.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.DataCase, only: [errors_on: 1]

  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{conn: conn, user: user}
  end

  describe "changeset" do
    test "links the member's own credential", %{user: user} do
      qualification = insert(:qualification, user: user, name: "Gesellenbrief Metallbauer")

      {:ok, work} =
        user
        |> Ecto.build_assoc(:work_experiences)
        |> WorkExperience.changeset(%{
          "title" => "Locksmith",
          "organization" => "Jane Doe's Smithy",
          "kind" => "employment",
          "qualification_id" => qualification.id
        })
        |> Repo.insert()

      assert work.qualification_id == qualification.id
    end

    test "rejects a credential belonging to another member", %{user: user} do
      other = insert_activated_user()
      foreign = insert(:qualification, user: other)

      changeset =
        user
        |> Ecto.build_assoc(:work_experiences)
        |> WorkExperience.changeset(%{
          "title" => "Locksmith",
          "organization" => "Jane Doe's Smithy",
          "kind" => "employment",
          "qualification_id" => foreign.id
        })

      refute changeset.valid?
      assert %{qualification_id: ["is invalid"]} = errors_on(changeset)
    end

    test "deleting the credential keeps the job and clears the link", %{user: user} do
      qualification = insert(:qualification, user: user)
      work = insert(:work_experience, user: user, qualification: qualification)

      Repo.delete!(qualification)

      assert %WorkExperience{qualification_id: nil} = Repo.reload!(work)
    end
  end

  describe "the form" do
    test "new renders no qualification select while the member holds no credentials",
         %{conn: conn} do
      html = conn |> get(~p"/settings/work_experiences/new") |> html_response(200)

      refute html =~ ~s(name="work_experience[qualification_id]")
    end

    test "new renders the select, grouped by kind, once credentials exist",
         %{conn: conn, user: user} do
      insert(:qualification, user: user, name: "Doctor of Medicine", kind: "certification")
      insert(:qualification, user: user, name: "Taxi licence", kind: "license", issuer: nil)

      html = conn |> get(~p"/settings/work_experiences/new") |> html_response(200)

      assert html =~ ~s(name="work_experience[qualification_id]")
      assert html =~ "Doctor of Medicine"
      assert html =~ "Taxi licence"
      # Grouped by kind, with a "None" default for the common unlinked job.
      assert html =~ "<optgroup"
      assert html =~ "Certificates"
      assert html =~ "Licenses"
      assert html =~ ">None<"
    end

    test "edit preselects the linked credential", %{conn: conn, user: user} do
      qualification = insert(:qualification, user: user, name: "Doctor of Medicine")
      work = insert(:work_experience, user: user, qualification: qualification)

      html = conn |> get(~p"/settings/work_experiences/#{work}/edit") |> html_response(200)

      assert html =~ ~s(<option selected value="#{qualification.id}">)
    end
  end

  describe "create and update" do
    test "create persists the link", %{conn: conn, user: user} do
      qualification = insert(:qualification, user: user)

      conn =
        post(conn, ~p"/settings/work_experiences", %{
          "work_experience" => %{
            "organization" => "St. Agatha Hospital",
            "title" => "Resident Physician",
            "kind" => "employment",
            "qualification_id" => qualification.id
          }
        })

      assert redirected_to(conn) == ~p"/settings/work_experiences"
      work = Repo.get_by!(WorkExperience, user_id: user.id)
      assert work.qualification_id == qualification.id
    end

    test "create with a foreign credential re-renders the form with an error",
         %{conn: conn, user: user} do
      insert(:qualification, user: user)
      foreign = insert(:qualification, user: insert_activated_user())

      conn =
        post(conn, ~p"/settings/work_experiences", %{
          "work_experience" => %{
            "organization" => "St. Agatha Hospital",
            "title" => "Resident Physician",
            "kind" => "employment",
            "qualification_id" => foreign.id
          }
        })

      assert html_response(conn, 422) =~ "check the fields"
      assert Repo.get_by(WorkExperience, user_id: user.id) == nil
    end

    test "update clears the link when qualification_id is blank", %{conn: conn, user: user} do
      qualification = insert(:qualification, user: user)
      work = insert(:work_experience, user: user, qualification: qualification)

      conn =
        put(conn, ~p"/settings/work_experiences/#{work}", %{
          "work_experience" => %{
            "organization" => work.organization,
            "title" => work.title,
            "kind" => "employment",
            "qualification_id" => ""
          }
        })

      assert redirected_to(conn) == ~p"/settings/work_experiences"
      assert is_nil(Repo.reload!(work).qualification_id)
    end
  end

  describe "public renderings" do
    setup %{user: user} do
      qualification = insert(:qualification, user: user, name: "Gesellenbrief Metallbauer")
      work = insert(:work_experience, user: user, qualification: qualification)
      %{qualification: qualification, work: work}
    end

    test "the section page shows the line linking to the credential",
         %{conn: conn, user: user, qualification: qualification} do
      html = conn |> get(~p"/#{user}/work_experiences") |> html_response(200)

      assert html =~ "With qualification:"
      assert html =~ ~p"/#{user}/qualifications/#{qualification}"
      assert html =~ "Gesellenbrief Metallbauer"
    end

    test "the profile Experience card shows the line", %{conn: conn, user: user} do
      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "With qualification:"
      assert html =~ "Gesellenbrief Metallbauer"
    end

    test "the entry show page names the credential",
         %{conn: conn, user: user, work: work, qualification: qualification} do
      html = conn |> get(~p"/#{user}/work_experiences/#{work}") |> html_response(200)

      assert html =~ "With qualification"
      assert html =~ ~p"/#{user}/qualifications/#{qualification}"
    end

    test "an unlinked job shows no qualification line", %{conn: conn, user: user} do
      html = conn |> get(~p"/#{user}") |> html_response(200)
      assert html =~ "With qualification:"

      other = insert_activated_user()
      insert(:work_experience, user: other)

      html = conn |> get(~p"/#{other}") |> html_response(200)
      refute html =~ "With qualification:"
    end
  end
end
