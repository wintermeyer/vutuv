defmodule Vutuv.PeopleHistoryTest do
  @moduledoc """
  The daily head-count history behind the investor page's growth curve: what a
  snapshot records, that a re-run corrects the day instead of doubling it, and
  that the growth summary can only ever describe the rows the curve is drawn
  from.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.BerlinTime
  alias Vutuv.Fediverse.Follower
  alias Vutuv.PeopleHistory
  alias Vutuv.PeopleHistory.Snapshot

  # The creating migration backfills 30 days, so even a fresh test database
  # starts with rows. Clearing them (inside the sandbox transaction, so it is
  # rolled back) lets each test state exactly which snapshots it expects.
  setup do
    Repo.delete_all(Snapshot)
    :ok
  end

  defp snapshot(day, members, fediverse) do
    {:ok, snapshot} =
      PeopleHistory.record(day, %{members: members, fediverse_accounts: fediverse})

    snapshot
  end

  describe "record/1" do
    test "records today's live member and Fediverse counts" do
      insert(:activated_user)
      insert(:activated_user)
      # An unconfirmed sign-up is not a member and must not appear in the curve.
      insert(:user, email_confirmed?: false)

      Repo.insert!(%Follower{
        actor_uri: "https://social.example/users/alice",
        inbox_uri: "https://social.example/users/alice/inbox",
        user: insert(:user)
      })

      assert {:ok, %Snapshot{} = snapshot} = PeopleHistory.record()

      assert snapshot.day == BerlinTime.today()
      assert snapshot.members == 2
      assert snapshot.fediverse_accounts == 1
    end
  end

  describe "record/2" do
    test "a second run corrects the day rather than drawing it twice" do
      day = ~D[2026-08-01]

      snapshot(day, 10, 3)
      snapshot(day, 12, 4)

      assert [%Snapshot{members: 12, fediverse_accounts: 4}] = Repo.all(Snapshot)
    end
  end

  describe "series/1" do
    test "returns the window oldest first and leaves out what is older" do
      today = BerlinTime.today()

      snapshot(Date.add(today, -40), 1, 0)
      snapshot(Date.add(today, -3), 5, 1)
      snapshot(Date.add(today, -1), 9, 2)

      assert [%{members: 5}, %{members: 9}] = PeopleHistory.series(30)
      assert [%{members: 1}, %{members: 5}, %{members: 9}] = PeopleHistory.series(90)
    end

    test "is empty while nothing has been recorded" do
      assert PeopleHistory.series() == []
    end
  end

  describe "growth/1" do
    test "is the difference between the first and the last snapshot" do
      series = [
        %Snapshot{day: ~D[2026-07-01], members: 100, fediverse_accounts: 20},
        %Snapshot{day: ~D[2026-07-15], members: 130, fediverse_accounts: 25},
        %Snapshot{day: ~D[2026-07-31], members: 150, fediverse_accounts: 45}
      ]

      assert %{
               from: ~D[2026-07-01],
               to: ~D[2026-07-31],
               days: 30,
               members: 50,
               fediverse_accounts: 25,
               total: 75
             } = PeopleHistory.growth(series)
    end

    test "has nothing to say about a series without a span" do
      assert PeopleHistory.growth([]) == nil
      assert PeopleHistory.growth([%Snapshot{day: ~D[2026-07-01], members: 1}]) == nil
    end
  end

  describe "curve_points/3" do
    test "draws one point per day, rising up the box" do
      series = [
        %Snapshot{day: ~D[2026-07-01], members: 100, fediverse_accounts: 0},
        %Snapshot{day: ~D[2026-07-16], members: 150, fediverse_accounts: 0},
        %Snapshot{day: ~D[2026-07-31], members: 200, fediverse_accounts: 0}
      ]

      [{x_first, y_first}, {_, y_middle}, {x_last, y_last}] =
        series |> PeopleHistory.curve_points(600, 140) |> parse()

      # The line spans the box from edge to edge, and a rising total is drawn
      # rising: in SVG that means a FALLING y, since y counts down from the top.
      assert x_first == 0.0
      assert x_last == 600.0
      assert y_first > y_middle
      assert y_middle > y_last

      # It keeps a hair of air at both ends, or the stroke of a peak is cut in
      # half by the edge of the box.
      assert y_last > 0.0
      assert y_first < 140.0
    end

    test "draws nothing for a series that is not a line" do
      # One day is no span, and a month that never moved is a flat lid: the
      # chart renders nothing rather than a line saying nothing.
      assert PeopleHistory.curve_points([], 600, 140) == nil

      assert PeopleHistory.curve_points([%Snapshot{day: ~D[2026-07-01], members: 1}], 600, 140) ==
               nil

      flat = [
        %Snapshot{day: ~D[2026-07-01], members: 100, fediverse_accounts: 5},
        %Snapshot{day: ~D[2026-07-31], members: 100, fediverse_accounts: 5}
      ]

      assert PeopleHistory.curve_points(flat, 600, 140) == nil
    end

    test "counts both populations, like the figure it is drawn beside" do
      series = [
        %Snapshot{day: ~D[2026-07-01], members: 100, fediverse_accounts: 0},
        %Snapshot{day: ~D[2026-07-31], members: 100, fediverse_accounts: 40}
      ]

      # Only the Fediverse half moved, and the line still has to show it.
      assert PeopleHistory.curve_points(series, 600, 140)
    end
  end

  # The point list back as `{x, y}` pairs, so a test can say what the line does
  # rather than match a string of coordinates.
  defp parse(points) do
    points
    |> String.split(" ")
    |> Enum.map(fn pair ->
      [x, y] = String.split(pair, ",")
      {String.to_float(x), String.to_float(y)}
    end)
  end
end
