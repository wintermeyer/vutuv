defmodule VutuvWeb.WorkExperienceKindTest do
  @moduledoc """
  The CV categories on work experiences (issue #840): a member files each
  entry as employment, self-employment (Freiberuflich / Selbstständig),
  internship (Praktikum), volunteering (Ehrenamt, Hobby & Freiwilligenarbeit,
  issue #916) or other activity (Sonstige Tätigkeit), and every list rendering
  groups the entries under distinctly labeled headings — but only once a
  non-employment entry exists, so the common jobs-only profile keeps its
  familiar single timeline.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Profiles.WorkExperience

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{conn: conn, user: user}
  end

  defp insert_job(user, attrs) do
    insert(
      :work_experience,
      Keyword.merge([user: user, start_month: 1, start_year: 2020], attrs)
    )
  end

  describe "the form" do
    test "new renders a category picker posting to the settings route", %{conn: conn} do
      html = conn |> get(~p"/settings/work_experiences/new") |> html_response(200)

      assert html =~ ~s(action="/settings/work_experiences")
      assert html =~ ~s(<select id="work_experience_kind" name="work_experience[kind]")
      assert html =~ ~s(value="employment")
      assert html =~ ~s(value="self_employed")
      assert html =~ ~s(value="internship")
      assert html =~ ~s(value="volunteer")
      assert html =~ ~s(value="other")
    end

    test "create persists the chosen category", %{conn: conn, user: user} do
      params = %{
        "organization" => "Water Watch",
        "title" => "River Guardian",
        "kind" => "volunteer"
      }

      conn = post(conn, ~p"/settings/work_experiences", %{"work_experience" => params})
      assert redirected_to(conn) == ~p"/settings/work_experiences"

      assert [%{kind: "volunteer"}] =
               Repo.all(Ecto.assoc(user, :work_experiences))
    end

    test "update moves an entry into another category", %{conn: conn, user: user} do
      job = insert_job(user, title: "Summer Intern", organization: "Acme Corp")

      edit_html =
        conn |> get(~p"/settings/work_experiences/#{job}/edit") |> html_response(200)

      assert edit_html =~ ~s(action="/settings/work_experiences/#{job.slug}")

      conn =
        put(conn, ~p"/settings/work_experiences/#{job}", %{
          "work_experience" => %{"kind" => "internship"}
        })

      assert redirected_to(conn) == ~p"/settings/work_experiences"
      assert Repo.get!(WorkExperience, job.id).kind == "internship"
    end
  end

  describe "the public section page" do
    test "groups entries under category headings once a non-employment entry exists",
         %{conn: conn, user: user} do
      insert_job(user, title: "Engineer", organization: "Acme Corp")
      insert_job(user, title: "Summer Intern", organization: "Beta GmbH", kind: "internship")
      insert_job(user, title: "River Guardian", organization: "Water Watch", kind: "volunteer")

      html = conn |> get(~p"/#{user}/work_experiences") |> html_response(200)

      assert html =~ "Professional Experience"
      assert html =~ "Internships"
      assert html =~ "Volunteering &amp; hobbies"
    end

    test "groups self-employment and other activities under their own headings",
         %{conn: conn, user: user} do
      insert_job(user, title: "Engineer", organization: "Acme Corp")
      insert_job(user, title: "Consultant", organization: "Solo", kind: "self_employed")
      insert_job(user, title: "Language Course", organization: "Volkshochschule", kind: "other")

      html = conn |> get(~p"/#{user}/work_experiences") |> html_response(200)

      assert html =~ "Freelance / Self-employed"
      assert html =~ "Other activities"
    end

    test "a jobs-only member keeps the single unlabeled timeline", %{conn: conn, user: user} do
      insert_job(user, title: "Engineer", organization: "Acme Corp")

      html = conn |> get(~p"/#{user}/work_experiences") |> html_response(200)

      refute html =~ "Professional Experience"
      refute html =~ "Internships"
      refute html =~ "Volunteering"
    end

    test "the owner's editor groups the same way", %{conn: conn, user: user} do
      insert_job(user, title: "Engineer", organization: "Acme Corp")
      insert_job(user, title: "River Guardian", organization: "Water Watch", kind: "volunteer")

      html = conn |> get(~p"/settings/work_experiences") |> html_response(200)

      assert html =~ "Professional Experience"
      assert html =~ "Volunteering &amp; hobbies"
    end

    # The duration circle used to sit in a fixed third grid column
    # (`grid-cols-[6.5rem_1fr_4rem]`), which reserved ~4rem of width down the
    # *whole* block height. On a phone that squeezed every role below the circle
    # into a narrow column while the space beside them sat empty. The circle now
    # floats into the top-right of the content column, so text wraps around it at
    # the top and reclaims the full card width below it. It floats inside a fixed
    # `w-16` box that centres it, so circles of every size share one vertical
    # centre line (floating the differently-sized circles directly only aligns
    # their right edges and staggers their centres).
    test "floats the duration circle so roles reclaim the width beside it (mobile)",
         %{conn: conn, user: user} do
      # Two roles at one employer make a block that runs several lines below the
      # circle — exactly where the wasted space showed.
      insert_job(user,
        title: "Staff Engineer",
        organization: "Acme Corp",
        start_month: 1,
        start_year: 2022
      )

      insert_job(user,
        title: "Senior Engineer",
        organization: "Acme Corp",
        start_month: 1,
        start_year: 2020,
        end_month: 12,
        end_year: 2021
      )

      html = conn |> get(~p"/#{user}/work_experiences") |> html_response(200)

      assert html =~ "float-right"
      # The fixed-width centring box that keeps every circle on one vertical axis.
      assert html =~ "w-16 justify-center"
      refute html =~ "grid-cols-[6.5rem_1fr_4rem]"
    end
  end

  describe "the entry show page" do
    test "names the category", %{conn: conn, user: user} do
      job =
        insert_job(user, title: "River Guardian", organization: "Water Watch", kind: "volunteer")

      html = conn |> get(~p"/#{user}/work_experiences/#{job}") |> html_response(200)

      assert html =~ "Category"
      assert html =~ "Volunteering &amp; hobbies"
    end

    test "names the self-employment category", %{conn: conn, user: user} do
      job =
        insert_job(user, title: "Consultant", organization: "Solo", kind: "self_employed")

      html = conn |> get(~p"/#{user}/work_experiences/#{job}") |> html_response(200)

      assert html =~ "Category"
      assert html =~ "Freelance / Self-employed"
    end
  end

  describe "the profile page" do
    test "the Experience card groups its preview under the same headings",
         %{conn: conn, user: user} do
      insert_job(user, title: "Engineer", organization: "Acme Corp")
      insert_job(user, title: "River Guardian", organization: "Water Watch", kind: "volunteer")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "Professional Experience"
      assert html =~ "Volunteering &amp; hobbies"
    end

    test "a jobs-only profile card shows no category headings", %{conn: conn, user: user} do
      insert_job(user, title: "Engineer", organization: "Acme Corp")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      refute html =~ "Professional Experience"
      refute html =~ "Volunteering"
    end
  end

  # Issue #916 (thanks to Dirk Deimeke): the volunteer category is where hobbies
  # and general volunteer work belong too, so its label says so in both
  # languages. Hobbies, especially in IT, are often not recognized as volunteer
  # work; naming them in the label invites members to file them here.
  describe "the volunteer category welcomes hobbies and volunteer work (issue #916)" do
    alias VutuvWeb.WorkExperienceHTML

    test "the English label names volunteering and hobbies" do
      Gettext.put_locale(VutuvWeb.Gettext, "en")

      assert WorkExperienceHTML.kind_name("volunteer") =~ "hobbies"
      assert WorkExperienceHTML.kind_label("volunteer") =~ "hobbies"
    end

    test "the German label names Ehrenamt, Hobby and Freiwilligenarbeit" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")

      for label <- [
            WorkExperienceHTML.kind_name("volunteer"),
            WorkExperienceHTML.kind_label("volunteer")
          ] do
        assert label =~ "Ehrenamt"
        assert label =~ "Hobby"
        assert label =~ "Freiwilligenarbeit"
      end
    end
  end
end
