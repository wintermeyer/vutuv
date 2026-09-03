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
  end

  test "a signed-in member also sees the members-only ones, never the hidden" do
    public = seeker(employment_status_visibility: "everyone")
    members_only = seeker(employment_status_visibility: "members")
    _hidden = seeker(employment_status_visibility: "hidden")
    viewer = insert(:activated_user)

    listed = ids(Accounts.open_to_offers(viewer))

    assert Enum.sort(listed) == Enum.sort([public.id, members_only.id])
  end

  test "a viewer on the seeker's exclusion list never sees them (issue #938)" do
    seeker = seeker(employment_status_visibility: "members")
    viewer = insert(:activated_user)
    insert(:viewer_exclusion, user: seeker, excluded_user: viewer, domain: nil)

    assert Accounts.open_to_offers(viewer) == []
  end

  test "an unconfirmed or moderation-hidden member is not listed" do
    _unconfirmed =
      insert(:user, employment_status: "looking", employment_status_visibility: "everyone")

    seeker(employment_status_visibility: "everyone", frozen_at: NaiveDateTime.utc_now(:second))

    assert Accounts.open_to_offers(nil) == []
  end

  test "the limit is honoured and the draw is random, not an order" do
    first = seeker(employment_status_visibility: "everyone")
    second = seeker(employment_status_visibility: "everyone")

    # Both are eligible, so a page of two holds both whatever the draw.
    assert Accounts.open_to_offers(nil) |> ids() |> Enum.sort() ==
             Enum.sort([first.id, second.id])

    # Drawing one of two, forty times: a fixed order would name the same member
    # every time. Missing one of them by chance is a 2^-39 event, so a failure
    # here is a lost draw, not a flake.
    drawn =
      for _ <- 1..40, reduce: MapSet.new() do
        seen -> MapSet.union(seen, MapSet.new(ids(Accounts.open_to_offers(nil, limit: 1))))
      end

    assert MapSet.size(drawn) == 2, "the draw always returned the same member"
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

    [row] = Accounts.open_to_offers(nil)

    assert row.employment_status == "open"
    assert row.desired_workplace_types == ["remote"]
    assert is_binary(row.username)
  end

  defp ids(people), do: Enum.map(people, & &1.id)
end
