defmodule VutuvWeb.CVLiveTest do
  @moduledoc """
  The interactive CV builder (issue #841): toggling a section, entry or
  identity field updates the download links so every export reflects the
  current selection; "Anonymize" hides the name/photo/contact in one click.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo

  defp seed(user) do
    insert(:work_experience,
      user: user,
      title: "Senior Developer",
      organization: "ACME GmbH",
      kind: "employment",
      start_year: 2020
    )

    insert(:work_experience,
      user: user,
      title: "Werkstudent",
      organization: "Beispiel AG",
      kind: "internship",
      start_year: 2018,
      end_year: 2019
    )

    insert(:education, user: user, school: "Universität Bremen", degree: "BSc", start_year: 2014)
    user
  end

  defp owner(_context) do
    user =
      seed(
        insert(:user,
          first_name: "Erika",
          last_name: "Beispiel",
          email_confirmed?: true
        )
      )

    %{owner: user}
  end

  describe "the builder page" do
    setup :owner

    test "renders the controls and the download panel", %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(conn, ~p"/#{owner}/cv")

      assert has_element?(view, "#cv-anonymize")
      assert has_element?(view, "#cv-reset")
      assert has_element?(view, "#cv-print")
      assert has_element?(view, "#cv-download-docx")
      assert has_element?(view, "#cv-download-json")
      # The full CV downloads carry no ?hide= until something is unticked.
      assert has_element?(view, "#cv-download-docx[href='/#{owner.username}/cv/download/docx']")
    end

    test "unticking a section encodes it into every download link", %{conn: conn, owner: owner} do
      internship = Repo.get_by(WorkExperience, title: "Werkstudent", user_id: owner.id)
      {:ok, view, _html} = live(conn, ~p"/#{owner}/cv")

      # A single entry (the internship) has its own toggle.
      assert has_element?(view, "input[phx-value-key='#{internship.id}']")

      # Hide the whole internship section (key "internship").
      view |> element("input[phx-value-key='internship']") |> render_click()

      assert has_element?(view, "#cv-download-docx[href*='hide=internship']")
      assert has_element?(view, "#cv-print[href*='hide=internship']")
    end

    test "Anonymize hides the identity fields in the download links", %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(conn, ~p"/#{owner}/cv")

      view |> element("#cv-anonymize") |> render_click()

      assert has_element?(view, "#cv-download-docx[href*='hide=']")
      assert has_element?(view, "#cv-download-docx[href*='name']")
      assert has_element?(view, "#cv-download-docx[href*='photo']")

      # Reset clears the selection: the links go back to the full CV.
      view |> element("#cv-reset") |> render_click()
      assert has_element?(view, "#cv-download-docx[href='/#{owner.username}/cv/download/docx']")
    end
  end

  describe "the JSON Resume download" do
    test "is offered for a machine-opted-out member too", %{conn: conn} do
      # The JSON Resume is a member-initiated CV export of the same public CV
      # as every other format, so the agent-doc opt-out no longer hides it.
      owner = seed(insert(:user, email_confirmed?: true, noindex?: true, noai?: true))

      {:ok, view, _html} = live(conn, ~p"/#{owner}/cv")

      assert has_element?(view, "#cv-download-docx")
      assert has_element?(view, "#cv-download-json")
    end
  end
end
