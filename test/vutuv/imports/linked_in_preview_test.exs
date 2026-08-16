defmodule Vutuv.Imports.LinkedInPreviewTest do
  @moduledoc """
  The preview layer of the LinkedIn import: `mark_duplicates/2` decides what the
  member already has, and `summary_rows/1` tallies that per section for the
  analysis summary the preview leads with (issue #1477).
  """
  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias Vutuv.Imports.LinkedIn

  defp zip(files) do
    entries = Enum.map(files, fn {name, content} -> {String.to_charlist(name), content} end)
    {:ok, {_name, binary}} = :zip.create(~c"export.zip", entries, [:memory])
    binary
  end

  defp positions_csv(rows) do
    "Company Name,Title,Description,Location,Started On,Finished On\n" <> rows
  end

  defp summary_for(user, files) do
    {:ok, parsed} = LinkedIn.parse(zip(files))

    user
    |> LinkedIn.mark_duplicates(parsed)
    |> LinkedIn.summary_rows()
    |> Map.new(fn row -> {row.key, row} end)
  end

  test "an entry the member already has counts as present, not as available" do
    user = insert(:user)
    insert(:work_experience, user: user, organization: "Acme", title: "Engineer")

    summary =
      summary_for(user, [
        {"Positions.csv",
         positions_csv("Acme,Engineer,,Berlin,2020,\nBeta,Developer,,Kiel,2021,\n")}
      ])

    assert summary.positions == %{key: :positions, found: 2, present: 1, available: 1}
  end

  test "a section the archive says nothing about is a row of zeros, not a missing row" do
    user = insert(:user)

    summary = summary_for(user, [{"Skills.csv", "Name\nElixir\n"}])

    # Every supported section is listed, so the member can see what we looked
    # for; the empty ones simply hold zeros rather than claiming a file is
    # missing (an empty section and an absent one look the same from here).
    assert summary.skills == %{key: :skills, found: 1, present: 0, available: 1}
    assert summary.certifications == %{key: :certifications, found: 0, present: 0, available: 0}
    assert summary.phones == %{key: :phones, found: 0, present: 0, available: 0}
  end

  # Profile scalars carry `fillable?` instead of `duplicate?`: the import only
  # ever fills a blank field, so a name the member already has is "present".
  test "a profile field that is already set counts as present" do
    user = insert(:user, first_name: "Ada", last_name: nil)

    profile_csv =
      "First Name,Last Name,Maiden Name,Address,Birth Date,Headline,Summary,Industry," <>
        "Zip Code,Geo Location,Twitter Handles,Websites,Instant Messengers\n" <>
        "Stefan,Wintermeyer,,,,,,,,,,,\n"

    summary = summary_for(user, [{"Profile.csv", profile_csv}])

    assert summary.profile == %{key: :profile, found: 2, present: 1, available: 1}
  end

  test "the archive's own repeated entries are collapsed before they are counted" do
    # A real export repeats entries across its files. They are one candidate,
    # so the summary must not report the extra copies as anything at all - an
    # "ignored" figure here would read as lost data.
    user = insert(:user)

    summary =
      summary_for(user, [
        {"Positions.csv", positions_csv("Acme,Engineer,,Berlin,2020,\n")},
        {"positions-2.csv", positions_csv("Acme,Engineer,,Berlin,2020,\n")}
      ])

    assert summary.positions == %{key: :positions, found: 1, present: 0, available: 1}
  end
end
