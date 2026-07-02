defmodule Vutuv.Imports.LinkedInApplyTest do
  @moduledoc """
  The DB side of the LinkedIn import: `apply_selection/2` inserts the chosen
  candidates, skips duplicates (so a re-import never doubles a row), and fills
  only blank profile fields.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias Vutuv.Imports.LinkedIn
  alias Vutuv.Profiles.Education
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Tags.UserTag

  defp zip(files) do
    entries = Enum.map(files, fn {name, content} -> {String.to_charlist(name), content} end)
    {:ok, {_name, binary}} = :zip.create(~c"export.zip", entries, [:memory])
    binary
  end

  defp sample_archive do
    zip([
      {"Positions.csv",
       "Company Name,Title,Description,Location,Started On,Finished On\nAcme,Engineer,,Berlin,2020,\n"},
      {"Education.csv",
       "School Name,Start Date,End Date,Notes,Degree Name,Activities\nMIT,2010,2014,,BSc,\n"},
      {"Skills.csv", "Name\nElixir\nPhoenix\n"}
    ])
  end

  test "inserts the selected candidates" do
    user = insert(:user)
    {:ok, parsed} = LinkedIn.parse(sample_archive())

    {:ok, summary} = LinkedIn.apply_selection(user, parsed)

    assert summary.created.positions == 1
    assert summary.created.educations == 1
    assert summary.created.skills == 2

    assert Repo.get_by(WorkExperience, user_id: user.id, organization: "Acme")
    assert Repo.get_by(Education, user_id: user.id, school: "MIT")
    assert Repo.aggregate(from(ut in UserTag, where: ut.user_id == ^user.id), :count) == 2
  end

  test "a second apply of the same selection inserts nothing (dedup)" do
    user = insert(:user)
    {:ok, parsed} = LinkedIn.parse(sample_archive())

    {:ok, _} = LinkedIn.apply_selection(user, parsed)
    {:ok, summary} = LinkedIn.apply_selection(user, parsed)

    assert summary.created.positions == 0
    assert summary.created.educations == 0
    assert summary.created.skills == 0
    assert summary.skipped.positions == 1

    # Still exactly one of each.
    assert Repo.aggregate(from(w in WorkExperience, where: w.user_id == ^user.id), :count) == 1
    assert Repo.aggregate(from(e in Education, where: e.user_id == ^user.id), :count) == 1
  end

  test "fills a blank headline but never overwrites an existing one" do
    blank = insert(:user, headline: nil)

    {:ok, blank_result} =
      LinkedIn.apply_selection(blank, %{profile: %{headline: "Imported line"}})

    assert blank_result.created.profile == [:headline]
    assert Repo.reload(blank).headline == "Imported line"

    set = insert(:user, headline: "My own headline")
    {:ok, set_result} = LinkedIn.apply_selection(set, %{profile: %{headline: "Imported line"}})
    assert set_result.created.profile == []
    assert Repo.reload(set).headline == "My own headline"
  end
end
