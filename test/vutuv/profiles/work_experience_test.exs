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
end
