defmodule Vutuv.Profiles.WorkExperienceTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Profiles.WorkExperience

  @current_year Date.utc_today().year

  defp changeset(params) do
    base = %{"organization" => "Acme", "title" => "Engineer"}
    WorkExperience.changeset(%WorkExperience{}, Map.merge(base, params))
  end

  describe "month" do
    test "accepts a month in 1..12" do
      assert changeset(%{"start_year" => 2000, "start_month" => 12}).valid?
    end

    test "rejects a month below 1" do
      cs = changeset(%{"start_year" => 2000, "start_month" => 0})

      refute cs.valid?
      assert %{start_month: [_]} = errors_on(cs)
    end

    test "rejects a month above 12" do
      cs = changeset(%{"end_year" => 2000, "end_month" => 13})

      refute cs.valid?
      assert %{end_month: [_]} = errors_on(cs)
    end

    test "still allows a year with no month (the form's prompt-not-selected case)" do
      assert changeset(%{"start_year" => 2000}).valid?
    end
  end

  describe "year" do
    test "accepts a year between 1920 and the current year" do
      assert changeset(%{"start_year" => 1999, "end_year" => @current_year}).valid?
    end

    test "rejects a start year in the future" do
      cs = changeset(%{"start_year" => @current_year + 1})

      refute cs.valid?
      assert %{start_year: [_]} = errors_on(cs)
    end

    test "rejects an end year in the future" do
      cs = changeset(%{"end_year" => @current_year + 5})

      refute cs.valid?
      assert %{end_year: [_]} = errors_on(cs)
    end

    test "rejects a year before 1920" do
      cs = changeset(%{"start_year" => 1919})

      refute cs.valid?
      assert %{start_year: [_]} = errors_on(cs)
    end
  end

  describe "existing range rule still holds" do
    test "rejects an end date earlier than the start date" do
      cs = changeset(%{"start_year" => 2010, "end_year" => 2005})

      refute cs.valid?
      assert %{end_month: [_]} = errors_on(cs)
    end
  end

  describe "kind (issue #840: employment | self_employed | internship | volunteer | other)" do
    test "defaults to employment when not given" do
      cs = changeset(%{})

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :kind) == "employment"
    end

    test "accepts each known category" do
      for kind <- WorkExperience.kinds() do
        cs = changeset(%{"kind" => kind})

        assert cs.valid?
        assert Ecto.Changeset.get_field(cs, :kind) == kind
      end
    end

    test "rejects an unknown category" do
      cs = changeset(%{"kind" => "hobby"})

      refute cs.valid?
      assert %{kind: [_]} = errors_on(cs)
    end

    test "a blank param falls back to the employment default, never NULL" do
      cs =
        WorkExperience.changeset(%WorkExperience{kind: "volunteer"}, %{
          "organization" => "Acme",
          "title" => "Chair",
          "kind" => ""
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :kind) == "employment"
    end

    test "rejects nulling the category (the column is NOT NULL)" do
      cs = changeset(%{"kind" => nil})

      refute cs.valid?
      assert %{kind: [_]} = errors_on(cs)
    end
  end

  describe "group_by_kind/1" do
    test "orders the groups employment, internship, volunteer and drops empty ones" do
      volunteer = %WorkExperience{kind: "volunteer", title: "Chair"}
      job = %WorkExperience{kind: "employment", title: "Engineer"}

      assert WorkExperience.group_by_kind([volunteer, job]) == [
               {"employment", [job]},
               {"volunteer", [volunteer]}
             ]
    end

    test "orders self_employed after employment and other last" do
      other = %WorkExperience{kind: "other", title: "Course"}
      self_employed = %WorkExperience{kind: "self_employed", title: "Consultant"}
      job = %WorkExperience{kind: "employment", title: "Engineer"}

      assert WorkExperience.group_by_kind([other, self_employed, job]) == [
               {"employment", [job]},
               {"self_employed", [self_employed]},
               {"other", [other]}
             ]
    end

    test "keeps the given (date) order within a group" do
      newer = %WorkExperience{kind: "internship", title: "Intern 2024"}
      older = %WorkExperience{kind: "internship", title: "Intern 2020"}

      assert WorkExperience.group_by_kind([newer, older]) == [
               {"internship", [newer, older]}
             ]
    end
  end
end
