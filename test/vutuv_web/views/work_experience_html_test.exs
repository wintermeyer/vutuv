defmodule VutuvWeb.WorkExperienceHTMLTest do
  @moduledoc """
  Pins the profile experience-rail helpers: duration circles and the
  year-range labels with their month tooltips.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Profiles.WorkExperience
  alias VutuvWeb.WorkExperienceHTML

  defp job(attrs) do
    struct(WorkExperience, Map.merge(%{title: "Role", organization: "Org"}, Map.new(attrs)))
  end

  describe "circle_durations/1" do
    test "labels roles by whole years, sub-year as <1, undated as blank" do
      [long, short, undated] =
        WorkExperienceHTML.circle_durations([
          job(start_year: 2004, start_month: 1, end_year: 2016, end_month: 1),
          job(start_year: 2003, start_month: 1, end_year: 2003, end_month: 6),
          job(start_year: nil, end_year: nil)
        ])

      assert long.label == "12"
      assert short.label == "<1"
      assert undated.label == ""
    end

    test "circle size grows with duration and the longest role fills the max" do
      [long, short] =
        WorkExperienceHTML.circle_durations([
          job(start_year: 2000, start_month: 1, end_year: 2012, end_month: 1),
          job(start_year: 2000, start_month: 1, end_year: 2002, end_month: 1)
        ])

      assert long.size > short.size
      assert long.size == 4.0
    end

    test "an undated role falls back to the smallest circle" do
      [circle] = WorkExperienceHTML.circle_durations([job(start_year: nil, end_year: nil)])

      assert circle.size == 1.6
      assert circle.label == ""
    end

    test "a short role is visibly smaller than a multi-year role" do
      [long, short] =
        WorkExperienceHTML.circle_durations([
          job(start_year: 2000, start_month: 1, end_year: 2002, end_month: 1),
          job(start_year: 2003, start_month: 3, end_year: 2003, end_month: 7)
        ])

      assert long.size - short.size > 0.4
    end

    test "results are returned in the given order" do
      circles =
        WorkExperienceHTML.circle_durations([
          job(title: "A", start_year: 2010, end_year: 2012),
          job(title: "B", start_year: 2000, end_year: 2009)
        ])

      assert Enum.map(circles, & &1.job.title) == ["A", "B"]
    end

    test "exposes a readable length (singular/plural), nil when undated" do
      [one_year, many_years, months, undated] =
        WorkExperienceHTML.circle_durations([
          job(start_year: 2010, start_month: 1, end_year: 2011, end_month: 1),
          job(start_year: 2000, start_month: 1, end_year: 2012, end_month: 1),
          job(start_year: 2003, start_month: 3, end_year: 2003, end_month: 7),
          job(start_year: nil, end_year: nil)
        ])

      assert one_year.length == "1 year"
      assert many_years.length == "12 years"
      assert months.length == "4 months"
      assert undated.length == nil
    end

    test "compact style labels whole years as Ny and sub-year spans as Nm" do
      [long, short] =
        WorkExperienceHTML.circle_durations(
          [
            job(start_year: 2000, start_month: 1, end_year: 2005, end_month: 1),
            job(start_year: 2003, start_month: 1, end_year: 2003, end_month: 4)
          ],
          :compact
        )

      assert long.label == "5y"
      assert short.label == "3m"
    end
  end

  describe "format_duration/5 ordering" do
    test "year_first writes the year before the month, month_first is the default" do
      assert IO.iodata_to_binary(
               WorkExperienceHTML.format_duration(3, 2018, 6, 2021, :year_first)
             ) == "2018/3 - 2021/6"

      assert IO.iodata_to_binary(WorkExperienceHTML.format_duration(3, 2018, 6, 2021)) ==
               "3/2018 - 6/2021"
    end
  end

  describe "duration_with_detail/4" do
    test "a multi-year span shows years only, with the exact range as the tooltip" do
      detail = WorkExperienceHTML.duration_with_detail(10, 2005, 6, 2017)

      assert IO.iodata_to_binary(detail.label) == "2005 - 2017"
      assert detail.detail == "2005/10 - 2017/6"
    end

    test "a single-year span shows just that year, with the months as the tooltip" do
      detail = WorkExperienceHTML.duration_with_detail(3, 2003, 7, 2003)

      assert IO.iodata_to_binary(detail.label) == "2003"
      assert detail.detail == "2003/3 - 2003/7"
    end

    test "a year-only single-year span shows the year and has no tooltip" do
      detail = WorkExperienceHTML.duration_with_detail(nil, 2003, nil, 2003)

      assert IO.iodata_to_binary(detail.label) == "2003"
      assert detail.detail == nil
    end

    test "an open-ended role counts as multi-year and runs to Present" do
      detail = WorkExperienceHTML.duration_with_detail(3, 2020, nil, nil)

      assert IO.iodata_to_binary(detail.label) == "2020 - Present"
      assert detail.detail == "2020/3 - Present"
    end
  end
end
