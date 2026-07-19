defmodule VutuvWeb.UserHelpersTest do
  @moduledoc """
  Pins the in-memory listing-page batching helpers against the DB-backed
  current_job/1 chain they replace (findings [43], [44], [49]).
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias VutuvWeb.UserHelpers

  import Vutuv.Factory
  import Vutuv.QueryCounter

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

  describe "a pinned profile job title wins over the heuristic (issue #833)" do
    test "current_job/1 returns the pinned role, not the heuristic pick" do
      user = insert(:user)
      # The heuristic would lead with the open-ended `current` role.
      current = we(user, start_month: 3, start_year: 2021, end_month: nil, end_year: nil)
      past = we(user, start_month: 1, start_year: 2015, end_month: 12, end_year: 2018)

      {:ok, user} = Vutuv.Accounts.pin_profile_work_experience(user, past)

      job = UserHelpers.current_job(user)
      assert job.id == past.id
      refute job.id == current.id
    end

    test "current_job_in_memory/2 returns the pinned role, else the heuristic" do
      user = insert(:user)
      current = we(user, start_month: 3, start_year: 2021, end_month: nil, end_year: nil)
      past = we(user, start_month: 1, start_year: 2015, end_month: 12, end_year: 2018)
      experiences = ordered_experiences(user)

      assert UserHelpers.current_job_in_memory(experiences, past.id).id == past.id
      assert UserHelpers.current_job_in_memory(experiences, nil).id == current.id
    end

    test "a pinned id that is not in the list falls back to the heuristic" do
      user = insert(:user)
      current = we(user, start_month: 3, start_year: 2021, end_month: nil, end_year: nil)
      experiences = ordered_experiences(user)

      assert UserHelpers.current_job_in_memory(experiences, Vutuv.UUIDv7.generate()).id ==
               current.id
    end

    test "deleting the pinned role nils the pointer, so it falls back (ON DELETE SET NULL)" do
      user = insert(:user)
      current = we(user, start_month: 3, start_year: 2021, end_month: nil, end_year: nil)
      past = we(user, start_month: 1, start_year: 2015, end_month: 12, end_year: 2018)
      {:ok, _} = Vutuv.Accounts.pin_profile_work_experience(user, past)

      Repo.delete!(past)
      user = Repo.get!(User, user.id)

      assert is_nil(user.profile_work_experience_id)
      assert UserHelpers.current_job(user).id == current.id
    end

    test "pinning rejects a work experience that belongs to someone else" do
      owner = insert(:user)
      _own = we(owner, title: "Owner Role", organization: "OwnCo")
      other = insert(:user)
      foreign = we(other, title: "Foreign Role", organization: "TheirCo")

      assert {:error, :not_owner} = Vutuv.Accounts.pin_profile_work_experience(owner, foreign)
      assert is_nil(Repo.get!(User, owner.id).profile_work_experience_id)
    end

    test "work_information_map/2 reflects the pinned title on a listing-fields struct" do
      user = insert(:user)

      _current =
        we(user,
          title: "New Role",
          organization: "NewCo",
          start_month: 3,
          start_year: 2021,
          end_month: nil,
          end_year: nil
        )

      past =
        we(user,
          title: "Old Role",
          organization: "OldCo",
          start_month: 1,
          start_year: 2015,
          end_month: 12,
          end_year: 2018
        )

      {:ok, _} = Vutuv.Accounts.pin_profile_work_experience(user, past)

      # Reload the way a listing query does, to prove the pin flows through the
      # partial listing_fields/0 struct, not just a full user row.
      listing_user =
        Repo.one!(
          from(u in User, where: u.id == ^user.id, select: struct(u, ^User.listing_fields()))
        )

      map = UserHelpers.work_information_map([listing_user], 60)
      assert Map.fetch!(map, user.id) == "Old Role @ OldCo"
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

  describe "age/2 (whole years on a reference day)" do
    test "counts a birthday that has already passed this year" do
      assert UserHelpers.age(~D[1990-04-15], ~D[2026-06-18]) == 36
    end

    test "the birthday itself already counts (inclusive)" do
      assert UserHelpers.age(~D[1990-06-18], ~D[2026-06-18]) == 36
    end

    test "a birthday still ahead this year has not been reached yet" do
      assert UserHelpers.age(~D[1990-12-25], ~D[2026-06-18]) == 35
    end

    test "the day before the birthday is still the lower age" do
      assert UserHelpers.age(~D[1990-06-19], ~D[2026-06-18]) == 35
    end

    test "a February 29 birthday rolls over on March 1 in non-leap years" do
      # Feb 28 in a non-leap year: the leapling has not turned older yet.
      assert UserHelpers.age(~D[2000-02-29], ~D[2026-02-28]) == 25
      assert UserHelpers.age(~D[2000-02-29], ~D[2026-03-01]) == 26
      # On a real Feb 29 the birthday lands exactly.
      assert UserHelpers.age(~D[2000-02-29], ~D[2024-02-29]) == 24
    end

    test "a birthdate in the future has no meaningful age" do
      assert UserHelpers.age(~D[2030-01-01], ~D[2026-06-18]) == nil
    end
  end

  describe "age/1 (current Berlin day)" do
    test "nil for a member without a birthdate" do
      assert UserHelpers.age(%User{birthdate: nil}) == nil
    end

    test "returns the whole-year age for a member with a birthdate" do
      birthdate = Date.add(Vutuv.BerlinTime.today(), -366 * 30)
      assert UserHelpers.age(%User{birthdate: birthdate}) in [29, 30]
    end
  end

  describe "format_birthdate_day_month/1 (day + month, no year)" do
    test "German locale drops the year, keeps the dd.mm. shape" do
      assert UserHelpers.format_birthdate_day_month(%User{
               locale: "de",
               birthdate: ~D[1990-04-23]
             }) == "23.04."
    end

    test "other locales use the mm/dd shape without the year" do
      assert UserHelpers.format_birthdate_day_month(%User{
               locale: "en",
               birthdate: ~D[1990-04-23]
             }) == "04/23"
    end

    test "no birthdate yields an empty string" do
      assert UserHelpers.format_birthdate_day_month(%User{birthdate: nil}) == ""
    end
  end

  describe "birthdate_visibility_options/0" do
    test "offers every schema-valid granularity with a label" do
      options = UserHelpers.birthdate_visibility_options()
      assert Enum.map(options, &elem(&1, 1)) == User.birthdate_visibilities()
      assert Enum.all?(options, fn {label, _value} -> is_binary(label) and label != "" end)
    end
  end

  describe "following_map/2" do
    test "returns followee_id => follow_id for followed users only" do
      follower = insert(:user)
      followed = insert(:user)
      not_followed = insert(:user)

      follow = insert(:follow, follower: follower, followee: followed)

      map = UserHelpers.following_map(follower, [followed, not_followed])

      assert map == %{followed.id => follow.id}
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
          insert(:follow, follower: follower, followee: u)
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

  describe "email visibility: a private address is owner-only" do
    # Privacy fix: `public?: false` used to mean "visible to everyone the owner
    # follows" (the email form literally said "Only those you follow can view").
    # An owner who follows 2,700 people thereby leaked their private address to
    # all 2,700. A private address is now visible to the owner and nobody else.
    test "user_has_permissions?/2 is true only for the owner themselves" do
      owner = insert(:user, email_confirmed?: true)
      stranger = insert(:user, email_confirmed?: true)

      assert UserHelpers.user_has_permissions?(owner, owner)
      refute UserHelpers.user_has_permissions?(owner, stranger)
      refute UserHelpers.user_has_permissions?(owner, nil)
    end

    test "neither a follower nor a member the owner follows (nor a mutual) gains access" do
      owner = insert(:user, email_confirmed?: true)
      follower = insert(:user, email_confirmed?: true)
      followed = insert(:user, email_confirmed?: true)
      mutual = insert(:user, email_confirmed?: true)

      insert(:follow, follower: follower, followee: owner)
      insert(:follow, follower: owner, followee: followed)
      insert(:follow, follower: owner, followee: mutual)
      insert(:follow, follower: mutual, followee: owner)

      refute UserHelpers.user_has_permissions?(owner, follower)
      refute UserHelpers.user_has_permissions?(owner, followed)
      refute UserHelpers.user_has_permissions?(owner, mutual)
    end

    test "emails_for_display/2 hands a private address only to the owner" do
      owner = insert(:user, email_confirmed?: true)
      followed = insert(:user, email_confirmed?: true)
      insert(:email, user: owner, public?: true, value: "public@example.com")
      insert(:email, user: owner, public?: false, value: "secret@example.com")
      insert(:follow, follower: owner, followee: followed)

      owner_sees = Enum.map(UserHelpers.emails_for_display(owner, owner), & &1.value)
      assert "public@example.com" in owner_sees
      assert "secret@example.com" in owner_sees

      followed_sees = Enum.map(UserHelpers.emails_for_display(owner, followed), & &1.value)
      assert "public@example.com" in followed_sees
      refute "secret@example.com" in followed_sees
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
end
