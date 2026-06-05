defmodule VutuvWeb.WorkExperienceHTMLTest do
  @moduledoc """
  Pins the horizontal-timeline layout helper. The behaviour the profile relies
  on is overlap handling: two roles whose date ranges intersect must land in
  separate lanes so their bars never stack on top of each other.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Profiles.WorkExperience
  alias VutuvWeb.WorkExperienceHTML

  defp job(attrs) do
    struct(WorkExperience, Map.merge(%{title: "Role", organization: "Org"}, Map.new(attrs)))
  end

  defp lane_titles(layout) do
    Enum.map(layout.lanes, fn lane -> Enum.map(lane, & &1.job.title) end)
  end

  describe "timeline_layout/1 lane packing" do
    test "non-overlapping roles share a single lane" do
      jobs = [
        job(title: "First", start_year: 2010, end_year: 2012),
        job(title: "Second", start_year: 2013, end_year: 2015)
      ]

      layout = WorkExperienceHTML.timeline_layout(jobs)

      assert layout.empty == false
      assert length(layout.lanes) == 1
      assert lane_titles(layout) == [["First", "Second"]]
    end

    test "overlapping roles are pushed into separate lanes" do
      jobs = [
        job(title: "Engineer", start_year: 2018, start_month: 3, end_year: 2021, end_month: 6),
        job(title: "Advisor", start_year: 2019, start_month: 1, end_year: 2023, end_month: 1)
      ]

      layout = WorkExperienceHTML.timeline_layout(jobs)

      assert length(layout.lanes) == 2
      # Each lane holds exactly one of the two overlapping roles.
      assert Enum.sort(List.flatten(lane_titles(layout))) == ["Advisor", "Engineer"]
      assert Enum.all?(layout.lanes, &(length(&1) == 1))
    end

    test "touching ranges (one ends as the next begins) still share a lane" do
      jobs = [
        job(title: "Before", start_year: 2010, start_month: 1, end_year: 2012, end_month: 6),
        job(title: "After", start_year: 2012, start_month: 6, end_year: 2014, end_month: 1)
      ]

      assert length(WorkExperienceHTML.timeline_layout(jobs).lanes) == 1
    end
  end

  describe "timeline_layout/1 bar geometry" do
    test "open-ended role is flagged present" do
      [bar] =
        [job(title: "Current", start_year: 2020, end_year: nil)]
        |> WorkExperienceHTML.timeline_layout()
        |> Map.fetch!(:lanes)
        |> List.flatten()

      assert bar.present == true
    end

    test "bars carry a visible width and sit within the axis" do
      layout =
        WorkExperienceHTML.timeline_layout([
          job(start_year: 2015, end_year: 2016),
          job(start_year: 2018, end_year: 2020)
        ])

      bars = List.flatten(layout.lanes)
      assert Enum.all?(bars, &(&1.width >= 1.5))
      assert Enum.all?(bars, &(&1.left >= 0 and &1.left <= 100))
    end

    test "year ticks run from the first to the last year of the span" do
      layout =
        WorkExperienceHTML.timeline_layout([job(start_year: 2010, end_year: 2014)])

      years = Enum.map(layout.ticks, & &1.year)
      assert List.first(years) == 2010
      assert List.last(layout.ticks).left == 100.0
      assert List.first(layout.ticks).left == 0.0
    end
  end

  describe "timeline_layout/1 with no placeable dates" do
    test "roles without any year are dropped, yielding an empty layout" do
      layout = WorkExperienceHTML.timeline_layout([job(start_year: nil, end_year: nil)])

      assert layout == %{empty: true, lanes: [], ticks: []}
    end
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
