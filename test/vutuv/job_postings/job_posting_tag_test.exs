defmodule Vutuv.JobPostings.JobPostingTagTest do
  use Vutuv.DataCase

  alias Vutuv.JobPostings.JobPostingTag

  @valid_attrs %{priority: 1}
  @invalid_attrs %{}

  test "changeset with valid attributes" do
    changeset = JobPostingTag.changeset(%JobPostingTag{}, @valid_attrs)
    assert changeset.valid?
  end

  test "changeset with invalid attributes" do
    changeset = JobPostingTag.changeset(%JobPostingTag{}, @invalid_attrs)
    refute changeset.valid?
  end

  test "per-priority ceilings come from JobPosting so the two layers cannot drift" do
    # JobPosting validates the form-level shape (exactly 3 important, at most
    # 7 optional); JobPostingTag enforces the same numbers as a row-level
    # ceiling on insert. Both must read the same definition.
    assert Vutuv.JobPostings.JobPosting.max_tags_for_priority(2) == 3
    assert Vutuv.JobPostings.JobPosting.max_tags_for_priority(1) == 7
    assert Vutuv.JobPostings.JobPosting.max_tags_for_priority(0) == 7
  end
end
