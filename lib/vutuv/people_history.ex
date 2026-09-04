defmodule Vutuv.PeopleHistory do
  @moduledoc """
  The daily history behind the live figures in `Vutuv.PeopleCounter`: one row
  per German calendar day with the member count and the Fediverse head count,
  written once a day by `Vutuv.PeopleHistory.Recorder` and drawn as the growth
  curve on `/system/investors`.

  Two counts, not one, because they grow for different reasons: members arrive
  through sign-up on this installation, Fediverse accounts arrive by following
  a member, a page or a tag from somewhere else entirely.

  The curve itself draws their **sum**, the figure the top bar shows. Two bands
  were tried and are not worth drawing: the member half is two orders of
  magnitude larger, so on any shared scale the Fediverse half is a hairline
  along the top. Which of the two moved is said in words under the chart
  instead, out of `growth/1`.

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

  # The top bar's thumbnail: how many days it draws and the box its points are
  # laid out in (stretched to the bar's few pixels by `preserveAspectRatio`).
  @spark_days 30
  @spark_width 100
  @spark_height 32
  @spark_key {__MODULE__, :spark}

  # How much of the drawn span is kept clear above and below the line, so a
  # peak's stroke is not cut in half by the edge of the box.
  @curve_margin 0.15

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
      total: Snapshot.total(last) - Snapshot.total(first)
    }
  end

  @doc """
  The same curve as a thumbnail for the top bar: `%{points:, days:, view_box:}`
  with the points ready for an SVG `polyline` in the box `view_box` names, or
  `nil` while there is nothing to draw.

  The box travels with the points on purpose: they mean nothing outside it, and
  a shell that spelled its own `viewBox` would draw a silently clipped line the
  day this one changes.

  Read from `:persistent_term`, never from the database — the bar sits on every
  page, so the figure beside it is two atomics reads (`Vutuv.PeopleCounter`)
  and this has to be as cheap. `Vutuv.PeopleCounter` refreshes it on the timer
  it already reconciles the member count with; until the first one lands (and
  in tests, where that timer is off) this answers `nil` and the bar simply
  shows the number, which is what it showed before.
  """
  def spark, do: :persistent_term.get(@spark_key, nil)

  @doc """
  Re-reads the last #{@spark_days} snapshots and caches the thumbnail.

  Writes only when the geometry actually changed: the rows behind it move once
  a day, and replacing a `:persistent_term` key costs a global scan whether or
  not the value is new. The read is not skipped, and does not need to be — it
  rides a tick that reads the whole member count beside it.
  """
  def refresh_spark do
    spark = spark_geometry(series(@spark_days))

    if spark != spark(), do: put_spark(spark)

    spark
  end

  defp put_spark(nil), do: clear_spark()
  defp put_spark(spark), do: :persistent_term.put(@spark_key, spark)

  @doc "Drop the cached thumbnail (test cleanup, like the other caches here)."
  def clear_spark, do: :persistent_term.erase(@spark_key)

  @doc """
  The thumbnail's geometry for a series, or `nil` where there is no line.

  A flat line is left undrawn on purpose. At this size it is a dash, and a dash
  beside the number reads as a chart that failed to load rather than as a week
  in which nobody joined.

  What the big curve adds and this one cannot, the two end figures that keep a
  zoomed axis honest, has no room in the chrome — which is why this shape says
  "rising" and the number beside it says how far.
  """
  def spark_geometry(series) do
    if points = curve_points(series, @spark_width, @spark_height) do
      first = List.first(series)
      last = List.last(series)

      %{
        points: points,
        days: Date.diff(last.day, first.day),
        view_box: "0 0 #{@spark_width} #{@spark_height}"
      }
    end
  end

  @doc """
  The series as the points of an SVG `polyline` in a `width` x `height` box, or
  `nil` where there is no line to draw: fewer than two days, or a total that
  never moved.

  Both drawings of this curve come through here — the chart on
  `/system/investors` and the thumbnail in the top bar — so how it is drawn is
  decided once. The vertical axis is the **span the data covers**, not zero to
  peak: at four digits a month of growth is a couple of hundred people, and an
  axis from zero draws that as a solid block with a flat lid. That zoom is only
  honest where something says what it spans, which is why the big chart names
  both ends underneath it.
  """
  def curve_points(series, _width, _height) when length(series) < 2, do: nil

  def curve_points(series, width, height) do
    totals = Enum.map(series, &Snapshot.total/1)
    {low, high} = Enum.min_max(totals)

    if high > low do
      margin = (high - low) * @curve_margin
      bottom = low - margin
      span = high + margin - bottom
      steps = length(series) - 1

      totals
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {total, index} ->
        x = index / steps * width
        y = height - (total - bottom) / span * height

        coordinate(x) <> "," <> coordinate(y)
      end)
    end
  end

  defp coordinate(value), do: :erlang.float_to_binary(value, decimals: 1)
end
