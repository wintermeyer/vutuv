defmodule Vutuv.JobPostings.JobPostingTest do
  use Vutuv.ModelCase

  alias Vutuv.JobPostings.JobPosting

  @valid_attrs %{
    user_id: 1,
    title: "Elixir Developer",
    description: "Looking for devs",
    location: "Berlin",
    open_on: ~D[2026-01-01],
    closed_on: ~D[2026-06-30]
  }
  @invalid_attrs %{}

  test "changeset with valid attributes" do
    changeset = JobPosting.changeset(%JobPosting{}, @valid_attrs)
    assert changeset.valid?
  end

  test "changeset with invalid attributes" do
    changeset = JobPosting.changeset(%JobPosting{}, @invalid_attrs)
    refute changeset.valid?
  end
end
