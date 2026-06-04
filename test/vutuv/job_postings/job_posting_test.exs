defmodule Vutuv.JobPostings.JobPostingTest do
  use Vutuv.DataCase

  alias Vutuv.JobPostings.JobPosting

  @valid_attrs %{
    title: "Elixir Developer",
    description: "Looking for devs",
    location: "Berlin",
    open_on: ~D[2026-01-01],
    closed_on: ~D[2026-06-30]
  }
  @invalid_attrs %{}

  # `user_id` is set programmatically via `Ecto.build_assoc(user, :job_postings)`
  # (see JobPostingController.create/2), never from request params. Mirror that
  # in the changeset's base struct so the required `user_id` is satisfied
  # without ever casting it from params.
  defp owned_job_posting(user_id), do: %JobPosting{user_id: user_id}

  test "changeset with valid attributes" do
    user = insert(:user)
    changeset = JobPosting.changeset(owned_job_posting(user.id), @valid_attrs)
    assert changeset.valid?
  end

  test "changeset with invalid attributes" do
    changeset = JobPosting.changeset(%JobPosting{}, @invalid_attrs)
    refute changeset.valid?
  end

  test "changeset does not cast user_id (cannot be smuggled via params)" do
    owner = insert(:user)
    other = insert(:user)

    changeset =
      JobPosting.changeset(
        owned_job_posting(owner.id),
        Map.put(@valid_attrs, :user_id, other.id)
      )

    # The owner's id (set on the struct) must win; the smuggled value is ignored.
    assert Ecto.Changeset.get_field(changeset, :user_id) == owner.id
    refute Ecto.Changeset.get_change(changeset, :user_id)
  end
end
