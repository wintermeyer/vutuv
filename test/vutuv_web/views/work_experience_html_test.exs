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

  describe "grouped_clusters/2" do
    test "consecutive roles at the same employer collapse into one company block" do
      [{"employment", [block]}] =
        WorkExperienceHTML.grouped_clusters([
          job(
            title: "Director",
            organization: "OX",
            start_year: 2022,
            start_month: 2,
            end_year: 2025,
            end_month: 3
          ),
          job(
            title: "Teamlead",
            organization: "OX",
            start_year: 2020,
            start_month: 3,
            end_year: 2022,
            end_month: 1
          ),
          job(
            title: "SDM",
            organization: "OX",
            start_year: 2016,
            start_month: 7,
            end_year: 2020,
            end_month: 2
          )
        ])

      assert block.multi?
      assert block.organization == "OX"
      assert Enum.map(block.roles, & &1.job.title) == ["Director", "Teamlead", "SDM"]
      # The header carries the span from the earliest start to the latest end and
      # the total tenure across the whole run, not any single role's.
      assert IO.iodata_to_binary(block.span.label) == "2016 - 2025"
      assert block.length == "9 years"
    end

    test "a lone role stays a single block that shows its organization inline" do
      [{"employment", [block]}] =
        WorkExperienceHTML.grouped_clusters([
          job(
            title: "TPO",
            organization: "x-ion",
            start_year: 2025,
            start_month: 3,
            end_year: nil,
            end_month: nil
          )
        ])

      refute block.multi?
      assert hd(block.roles).job.title == "TPO"
      assert IO.iodata_to_binary(block.span.label) == "2025 - Present"
    end

    test "two stints at the same employer with another job between stay separate blocks" do
      [{"employment", blocks}] =
        WorkExperienceHTML.grouped_clusters([
          job(
            title: "Later",
            organization: "Alt",
            start_year: 2011,
            start_month: 1,
            end_year: 2016,
            end_month: 1
          ),
          job(
            title: "Mid",
            organization: "Amooma",
            start_year: 2011,
            start_month: 1,
            end_year: 2011,
            end_month: 10
          ),
          job(
            title: "Early",
            organization: "Alt",
            start_year: 2001,
            start_month: 1,
            end_year: 2010,
            end_month: 1
          )
        ])

      assert Enum.map(blocks, & &1.organization) == ["Alt", "Amooma", "Alt"]
      assert Enum.map(blocks, & &1.multi?) == [false, false, false]
    end

    test "roles of different categories never merge, even at the same employer" do
      assert [{"employment", [emp]}, {"internship", [intern]}] =
               WorkExperienceHTML.grouped_clusters([
                 job(
                   title: "Job",
                   organization: "Acme",
                   kind: "employment",
                   start_year: 2020,
                   end_year: 2022
                 ),
                 job(
                   title: "Intern",
                   organization: "Acme",
                   kind: "internship",
                   start_year: 2019,
                   end_year: 2020
                 )
               ])

      refute emp.multi?
      refute intern.multi?
    end

    test "roles without an organization are never clustered together" do
      [{"employment", blocks}] =
        WorkExperienceHTML.grouped_clusters([
          job(title: "A", organization: "", start_year: 2020, end_year: 2021),
          job(title: "B", organization: "", start_year: 2018, end_year: 2019)
        ])

      assert length(blocks) == 2
      assert Enum.all?(blocks, &(not &1.multi?))
    end

    test "the block circle is ranked by the employer's total tenure, not the longest single role" do
      [{"employment", [cluster, solo]}] =
        WorkExperienceHTML.grouped_clusters(
          [
            job(
              title: "A2",
              organization: "A",
              start_year: 2010,
              start_month: 1,
              end_year: 2015,
              end_month: 1
            ),
            job(
              title: "A1",
              organization: "A",
              start_year: 2005,
              start_month: 1,
              end_year: 2010,
              end_month: 1
            ),
            job(
              title: "B",
              organization: "B",
              start_year: 2000,
              start_month: 1,
              end_year: 2003,
              end_month: 1
            )
          ],
          :compact
        )

      # The 10-year run at "A" (two 5-year roles) fills the largest circle even
      # though no single role is longer than the 3-year "B".
      assert cluster.multi?
      assert cluster.label == "10y"
      assert cluster.size == 4.0
      assert cluster.size > solo.size
    end
  end

  describe "grouped_clusters/3 display limit" do
    test "caps the shown roles but keeps each employer's full tenure" do
      # x-ion (1 role) + 2 of Open-Xchange's 3 roles fit under a 3-role cap; the
      # third OX role is cut, but the block must still report the whole 9-year,
      # 2016-2025 tenure — not just the two shown roles' span. Regression guard:
      # a company cut mid-cluster on the profile preview reported too few years.
      [{"employment", [x_ion, ox]}] =
        WorkExperienceHTML.grouped_clusters(
          [
            job(title: "TPO", organization: "x-ion", start_year: 2025, start_month: 3),
            job(
              title: "Director",
              organization: "OX",
              start_year: 2022,
              start_month: 2,
              end_year: 2025,
              end_month: 3
            ),
            job(
              title: "Teamlead",
              organization: "OX",
              start_year: 2020,
              start_month: 3,
              end_year: 2022,
              end_month: 1
            ),
            job(
              title: "SDM",
              organization: "OX",
              start_year: 2016,
              start_month: 7,
              end_year: 2020,
              end_month: 2
            )
          ],
          :compact,
          3
        )

      refute x_ion.multi?
      assert Enum.map(ox.roles, & &1.job.title) == ["Director", "Teamlead"]
      assert ox.length == "9 years"
      assert ox.label == "9y"
      assert IO.iodata_to_binary(ox.span.label) == "2016 - 2025"
    end

    test "a limit at or above the role count shows every role" do
      [{"employment", blocks}] =
        WorkExperienceHTML.grouped_clusters(
          [
            job(title: "A", organization: "Acme", start_year: 2022, end_year: 2024),
            job(title: "B", organization: "Beta", start_year: 2020, end_year: 2022)
          ],
          :compact,
          10
        )

      assert Enum.flat_map(blocks, & &1.roles) |> length() == 2
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
