defmodule Vutuv.JobPostings.JobPostingTagTest do
  use Vutuv.ModelCase

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
end
