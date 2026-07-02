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

  # The (value, provider) unique index on social_media_accounts is GLOBAL: a
  # handle someone else already claimed can never be imported. It must be
  # counted as skipped WITHOUT the insert firing the constraint — inside the
  # one import transaction that error aborts the transaction at the Postgres
  # level and every later insert dies with 25P02 (this 500ed real imports: the
  # member's Twitter handle belonged to another account, and the phone insert
  # right after it crashed).
  test "a social account claimed by another member is skipped, the rest still lands" do
    other = insert(:user)
    insert(:social_media_account, user: other, provider: "Twitter", value: "wintermeyer")

    user = insert(:user)

    profile_csv =
      "First Name,Last Name,Maiden Name,Address,Birth Date,Headline,Summary,Industry,Zip Code,Geo Location,Twitter Handles,Websites,Instant Messengers\n" <>
        "Stefan,Wintermeyer,,,,,,,,,[wintermeyer],,\n"

    phones_csv = "Extension,Number,Type\n,+49 30 901820,Work\n"

    {:ok, parsed} =
      LinkedIn.parse(zip([{"Profile.csv", profile_csv}, {"PhoneNumbers.csv", phones_csv}]))

    {:ok, summary} = LinkedIn.apply_selection(user, parsed)

    # The claimed handle is skipped; the phone AFTER it still imports.
    assert summary.created.social == 0
    assert summary.skipped.social == 1
    assert summary.created.phones == 1

    assert Repo.aggregate(
             from(p in Vutuv.Profiles.PhoneNumber, where: p.user_id == ^user.id),
             :count
           ) == 1
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
