defmodule Vutuv.Accounts.OpenToOffersTest do
  @moduledoc """
  `Accounts.open_to_offers/2`: the members who said they are available, as a
  listing rather than one profile at a time.

  It is the same availability signal the profile badge shows (issue #928), so
  it obeys the same three-way visibility and the same job-search exclusion list
  (#938). A listing multiplies the cost of getting that wrong: a profile leaks
  one member's status to one visitor, a list hands a crawler everybody's.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Repo

  defp seeker(attrs) do
    insert(:activated_user, Keyword.merge([employment_status: "open"], attrs))
  end

  test "lists only members who set a status" do
    available = seeker(employment_status_visibility: "everyone")
    _quiet = insert(:activated_user, employment_status: nil)

    assert ids(Accounts.open_to_offers(nil)) == [available.id]
  end

  test "a logged-out visitor sees only the members open to everyone" do
    public = seeker(employment_status_visibility: "everyone")
    _members_only = seeker(employment_status_visibility: "members")
    _hidden = seeker(employment_status_visibility: "hidden")

    assert ids(Accounts.open_to_offers(nil)) == [public.id]
    assert Accounts.open_to_offers(nil).total == 1
  end

  test "a signed-in member also sees the members-only ones, never the hidden" do
    public = seeker(employment_status_visibility: "everyone")
    members_only = seeker(employment_status_visibility: "members")
    _hidden = seeker(employment_status_visibility: "hidden")
    viewer = insert(:activated_user)

    listed = ids(Accounts.open_to_offers(viewer))

    assert Enum.sort(listed) == Enum.sort([public.id, members_only.id])
    assert Accounts.open_to_offers(viewer).total == 2
  end

  test "a viewer on the seeker's exclusion list never sees them (issue #938)" do
    seeker = seeker(employment_status_visibility: "members")
    viewer = insert(:activated_user)
    insert(:viewer_exclusion, user: seeker, excluded_user: viewer, domain: nil)

    # The count is the same answer as the list, so an excluded viewer is not
    # told "one member is looking" by a number they can never resolve to a row.
    assert Accounts.open_to_offers(viewer) == %{people: [], total: 0}
  end

  test "an unconfirmed or moderation-hidden member is not listed" do
    _unconfirmed =
      insert(:user, employment_status: "looking", employment_status_visibility: "everyone")

    seeker(employment_status_visibility: "everyone", frozen_at: NaiveDateTime.utc_now(:second))

    assert Accounts.open_to_offers(nil) == %{people: [], total: 0}
  end

  test "the freshest signal comes first, and the limit is honoured" do
    older = seeker(employment_status_visibility: "everyone")
    newer = seeker(employment_status_visibility: "everyone")

    stamp(older, ~N[2026-01-01 10:00:00])
    stamp(newer, ~N[2026-09-01 10:00:00])

    assert ids(Accounts.open_to_offers(nil)) == [newer.id, older.id]

    # The limit shortens the list and not the count: the page says "showing 1
    # of 2", never "there is 1".
    assert Accounts.open_to_offers(nil, limit: 1) |> ids() == [newer.id]
    assert Accounts.open_to_offers(nil, limit: 1).total == 2
  end

  # The listing gate is SQL and `User.employment_status_visible?/2` is pattern
  # matching over a loaded struct — two spellings of the one #928 rule, which is
  # exactly the shape that drifts. This pins them to each other: every
  # visibility value, seen by nobody and by a signed-in member.
  test "the SQL gate answers what the struct predicate answers" do
    viewer = insert(:activated_user)

    for visibility <- ["everyone", "members", "hidden", nil],
        {label, looker} <- [{"anonymous", nil}, {"signed in", viewer}] do
      member = seeker(employment_status_visibility: visibility)
      listed? = member.id in ids(Accounts.open_to_offers(looker))
      predicate? = User.employment_status_visible?(member, looker)

      assert listed? == predicate?,
             "#{label} viewer, visibility #{inspect(visibility)}: listing says #{listed?}, " <>
               "employment_status_visible?/2 says #{predicate?}"

      Repo.delete!(member)
    end
  end

  test "the rows carry what a listing card draws, without a second query" do
    seeker(employment_status_visibility: "everyone", desired_workplace_types: ["remote"])

    %{people: [row]} = Accounts.open_to_offers(nil)

    assert row.employment_status == "open"
    assert row.desired_workplace_types == ["remote"]
    assert is_binary(row.username)
  end

  defp ids(%{people: people}), do: Enum.map(people, & &1.id)

  defp stamp(user, at) do
    user
    |> Ecto.Changeset.change(employment_status_set_at: at)
    |> Repo.update!()
  end
end
