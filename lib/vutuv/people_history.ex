defmodule Vutuv.PeopleHistory do
  @moduledoc """
  The daily history behind the live figures in `Vutuv.PeopleCounter`: one row
  per German calendar day with the member count and the Fediverse head count,
  written once a day by `Vutuv.PeopleHistory.Recorder` and drawn as the growth
  curve on `/system/investors`.

  Two counts, not one, because they grow for different reasons: members arrive
  through sign-up on this installation, Fediverse accounts arrive by following
  a member, a page or a tag from somewhere else entirely. A single "people"
  line would hide which of the two is moving.

  The first 30 days in the table are a reconstruction written by the creating
  migration and read a little low (deleted members and pruned followers can no
  longer be counted); see the migration's moduledoc. Nothing here treats them
  differently.
  """

  import Ecto.Query

  alias Vutuv.Accounts
  alias Vutuv.BerlinTime
  alias Vutuv.Fediverse
  alias Vutuv.PeopleHistory.Snapshot
  alias Vutuv.Repo

  @doc """
  Writes (or rewrites) the snapshot for `day`, defaulting to the German
  calendar day that is ending. Counting happens here rather than in the caller
  so the recorder and a manual re-run record the same thing.
  """
  def record(day \\ BerlinTime.today()) do
    record(day, %{
      members: Accounts.count_users(),
      fediverse_accounts: Fediverse.distinct_follower_count()
    })
  end

  @doc """
  Writes `counts` (`%{members:, fediverse_accounts:}`) as the snapshot for
  `day`, replacing an existing row for that day.

  Replacing rather than skipping matters on a re-run: the second write is the
  later, better reading of the same day, and a crashed or restarted recorder
  must not leave the day out of the curve.
  """
  def record(%Date{} = day, %{members: members, fediverse_accounts: fediverse_accounts}) do
    %Snapshot{}
    |> Snapshot.changeset(%{
      day: day,
      members: members,
      fediverse_accounts: fediverse_accounts
    })
    |> Repo.insert(
      on_conflict: [set: [members: members, fediverse_accounts: fediverse_accounts]],
      conflict_target: :day
    )
  end

  @doc """
  The last `days` snapshots, oldest first — what the growth curve is drawn
  from. Returns `[]` while the table is empty, which every caller must render
  as "no curve yet" rather than as a flat line at zero.
  """
  def series(days \\ 90) when is_integer(days) and days > 0 do
    Repo.all(
      from(s in Snapshot,
        where: s.day > ^Date.add(BerlinTime.today(), -days),
        order_by: [asc: s.day]
      )
    )
  end

  @doc """
  The growth over the series' own span: `%{from:, to:, days:, members:,
  fediverse_accounts:, total:}` with each figure the difference between the
  last and the first snapshot, or `nil` for a series too short to have a span.

  Deliberately derived from the same rows the curve is drawn from, so the
  sentence under the chart can never claim a rise the chart does not show.
  """
  def growth([]), do: nil
  def growth([_only]), do: nil

  def growth([first | _] = series) do
    last = List.last(series)

    %{
      from: first.day,
      to: last.day,
      days: Date.diff(last.day, first.day),
      members: last.members - first.members,
      fediverse_accounts: last.fediverse_accounts - first.fediverse_accounts,
      total: last.members + last.fediverse_accounts - (first.members + first.fediverse_accounts)
    }
  end
end
