defmodule VutuvWeb.UserHelpersTest do
  @moduledoc """
  Pins the in-memory listing-page batching helpers against the DB-backed
  current_job/1 chain they replace (findings [43], [44], [49]).
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Repo
  alias VutuvWeb.UserHelpers

  import Vutuv.Factory

  # A work experience with explicit dates; ExMachina's factory always sets a
  # start_month/start_year, so override them per case.
  defp we(user, attrs) do
    insert(:work_experience, Map.merge(%{user: user}, Map.new(attrs)))
  end

  describe "current_job_in_memory/1 reproduces the DB-backed current_job/1 precedence" do
    test "no work experiences -> nil (both)" do
      user = insert(:user)
      assert UserHelpers.current_job(user) == nil
      assert UserHelpers.current_job_in_memory([]) == nil
    end

    test "prefers the experience that has a start and no end" do
      user = insert(:user)
      # An older, ended job inserted first; a current (no end) job inserted later.
      _ended = we(user, start_month: 1, start_year: 2018, end_month: 12, end_year: 2019)
      current = we(user, start_month: 3, start_year: 2021, end_month: nil, end_year: nil)

      db_job = UserHelpers.current_job(user)
      assert db_job.id == current.id

      experiences = ordered_experiences(user)
      assert UserHelpers.current_job_in_memory(experiences).id == db_job.id
    end

    test "falls back to a no-end experience even when the start is missing" do
      user = insert(:user)
      # No start, no end. Should win over the older ended job.
      _ended = we(user, start_month: 1, start_year: 2010, end_month: 6, end_year: 2012)
      no_start = we(user, start_month: nil, start_year: nil, end_month: nil, end_year: nil)

      db_job = UserHelpers.current_job(user)
      assert db_job.id == no_start.id
      assert UserHelpers.current_job_in_memory(ordered_experiences(user)).id == db_job.id
    end

    test "with only ended jobs, picks the most recent by start_year/start_month" do
      user = insert(:user)
      _older = we(user, start_month: 5, start_year: 2015, end_month: 1, end_year: 2017)
      newer = we(user, start_month: 9, start_year: 2019, end_month: 1, end_year: 2021)

      db_job = UserHelpers.current_job(user)
      assert db_job.id == newer.id
      assert UserHelpers.current_job_in_memory(ordered_experiences(user)).id == db_job.id
    end

    test "most-recent tie on year breaks on the later start_month" do
      user = insert(:user)
      _jan = we(user, start_month: 1, start_year: 2020, end_month: 2, end_year: 2020)
      nov = we(user, start_month: 11, start_year: 2020, end_month: 12, end_year: 2020)

      db_job = UserHelpers.current_job(user)
      assert db_job.id == nov.id
      assert UserHelpers.current_job_in_memory(ordered_experiences(user)).id == db_job.id
    end

    test "most-recent path sorts a nil start first, matching Postgres DESC NULLS FIRST" do
      user = insert(:user)
      # Both ended (so the no-end fallback never triggers) and the most-recent
      # branch runs. The DB query orders desc by start_year/start_month, and
      # Postgres puts NULLs first in a DESC order, so the nil-start row is the
      # "most recent". The in-memory variant must reproduce that exactly.
      _with_start = we(user, start_month: 3, start_year: 2016, end_month: 4, end_year: 2018)
      no_start = we(user, start_month: nil, start_year: nil, end_month: 4, end_year: 2018)

      db_job = UserHelpers.current_job(user)
      assert db_job.id == no_start.id
      assert UserHelpers.current_job_in_memory(ordered_experiences(user)).id == db_job.id
    end
  end

  describe "work_information_string_for_job/2 matches work_information_string/2" do
    test "current job with title and organization" do
      user = insert(:user)
      we(user, title: "CTO", organization: "Acme", end_month: nil, end_year: nil)

      job = UserHelpers.current_job(user)

      assert UserHelpers.work_information_string(user, 60) ==
               UserHelpers.work_information_string_for_job(job, 60)

      assert UserHelpers.work_information_string_for_job(job, 60) == "CTO @ Acme"
    end

    test "no experience yields an empty string both ways" do
      user = insert(:user)
      assert UserHelpers.work_information_string(user, 60) == ""
      assert UserHelpers.work_information_string_for_job(nil, 60) == ""
    end
  end

  describe "work_information_map/2" do
    test "matches per-user work_information_string/2 in one batched query" do
      user1 = insert(:user)
      we(user1, title: "Dev", organization: "Foo", end_month: nil, end_year: nil)
      user2 = insert(:user)
      we(user2, title: "PM", organization: "Bar", end_month: 12, end_year: 2020)
      user3 = insert(:user)

      users = [user1, user2, user3]

      map = UserHelpers.work_information_map(users, 60)

      for user <- users do
        assert Map.fetch!(map, user.id) == UserHelpers.work_information_string(user, 60)
      end
    end

    test "empty list -> empty map" do
      assert UserHelpers.work_information_map([], 60) == %{}
    end
  end

  describe "following_map/2" do
    test "returns followee_id => connection_id for followed users only" do
      follower = insert(:user)
      followed = insert(:user)
      not_followed = insert(:user)

      connection = insert(:connection, follower: follower, followee: followed)

      map = UserHelpers.following_map(follower, [followed, not_followed])

      assert map == %{followed.id => connection.id}
    end

    test "no current_user -> empty map" do
      assert UserHelpers.following_map(nil, [insert(:user)]) == %{}
    end
  end

  describe "query-count regression for the batched listing helpers" do
    test "work_information_map + following_map stay at a small constant for N users" do
      follower = insert(:user)

      users =
        for _ <- 1..20 do
          u = insert(:user)
          insert(:work_experience, user: u, end_month: nil, end_year: nil)
          insert(:connection, follower: follower, followee: u)
          u
        end

      {_, count} =
        count_queries(fn ->
          UserHelpers.work_information_map(users, 60)
          UserHelpers.following_map(follower, users)
        end)

      # One query for the work experiences, one for the follow set. The whole
      # point of the batching is that this does not grow with the 20 users.
      assert count <= 2,
             "expected the batched helpers to run at most 2 queries, got #{count}"
    end
  end

  # Re-read the work experiences in the same id order the listing helpers use
  # (work_information_map orders by w.id), so current_job_in_memory sees the
  # same physical ordering the DB-backed limit-1 queries rely on.
  defp ordered_experiences(user) do
    Repo.all(
      from(w in Vutuv.Profiles.WorkExperience, where: w.user_id == ^user.id, order_by: w.id)
    )
  end

  defp count_queries(fun) do
    parent = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:vutuv, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        # Telemetry is global; under async tests, only count queries emitted
        # from this test process (Ecto runs the handler in the caller).
        if self() == parent, do: send(parent, {ref, :query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_queries(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(ref, acc) do
    receive do
      {^ref, :query} -> drain_queries(ref, acc + 1)
    after
      0 -> acc
    end
  end
end
