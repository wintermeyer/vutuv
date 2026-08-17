defmodule Vutuv.BerlinTime do
  @moduledoc """
  "What day is it in Germany?" — the **installation's** clock, as opposed to the
  reader's own (`Vutuv.ViewerClock`, issue #1502).

  This is the single source for the German calendar day, and it is deliberately
  one fixed zone rather than a per-viewer one: the daily ad rotation
  (`Vutuv.Ads`) books and serves ads by it, the nightly workers wake on it, the
  daily report counts by it, and the profile age display
  (`VutuvWeb.UserHelpers.age/1`) rolls a member's age over at German local
  midnight. Those are all facts about the site, not about whoever is looking.

  The offsets come from the IANA time zone database (`tz`, configured in
  `config/config.exs`), so the two switch days a year need no special handling.
  """

  @zone "Europe/Berlin"

  @doc "Today as a German calendar day (Europe/Berlin)."
  def today, do: date(DateTime.utc_now())

  @doc "The current Europe/Berlin wall-clock time as a `NaiveDateTime`."
  def now, do: naive(DateTime.utc_now())

  @doc "A UTC instant as Europe/Berlin wall-clock time (a `NaiveDateTime`)."
  def naive(%DateTime{} = utc), do: utc |> DateTime.shift_zone!(@zone) |> DateTime.to_naive()

  @doc "The German calendar date of a UTC instant."
  def date(%DateTime{} = utc), do: utc |> naive() |> NaiveDateTime.to_date()

  @doc """
  The UTC half-open instant range `[start, finish)` that spans a whole German
  calendar day, as `NaiveDateTime`s (the type Ecto stores `inserted_at` in).
  Use it to bucket UTC timestamps by German calendar day, e.g. counting a
  day's registrations and posts (`Vutuv.Reports`).
  """
  def day_bounds_utc(%Date{} = date) do
    {local_midnight_utc(date), local_midnight_utc(Date.add(date, 1))}
  end

  @doc """
  Milliseconds from now until the next Berlin-local 00:`minute_offset` (a few
  minutes past German midnight), computed in UTC off the Berlin-day midnight
  instants so it lands on the wall-clock minute through both DST halves. The
  one scheduling clock of the nightly workers - `Vutuv.Reports.DailyReporter`
  (:05), `Vutuv.Jobs.Sweeper` (:10) and `Vutuv.SavedSearches.AlertSweeper`
  (:20) - each keeping only its own minute constant.
  """
  def ms_until_daily_trigger(minute_offset) when is_integer(minute_offset) do
    now = DateTime.to_naive(DateTime.utc_now())
    today = today()
    today_trigger = trigger_instant(today, minute_offset)

    target =
      if NaiveDateTime.compare(now, today_trigger) == :lt,
        do: today_trigger,
        else: trigger_instant(Date.add(today, 1), minute_offset)

    max(NaiveDateTime.diff(target, now, :millisecond), 0)
  end

  # The Berlin-local 00:MM instant of `date`, as a UTC NaiveDateTime.
  defp trigger_instant(date, minute_offset) do
    NaiveDateTime.add(local_midnight_utc(date), minute_offset * 60, :second)
  end

  # Berlin-local 00:00 of `date`, expressed as a UTC NaiveDateTime.
  defp local_midnight_utc(date), do: date |> local_midnight_as_utc() |> DateTime.to_naive()

  # Berlin-local 00:00 of `date`, expressed as a UTC DateTime. Berlin has never
  # switched its clocks at midnight (the change is at 02:00/03:00 local), so the
  # gap and ambiguous branches are unreachable in practice — they are here so a
  # future rule change would move a boundary by an hour rather than raise inside
  # a scheduler.
  defp local_midnight_as_utc(date) do
    case DateTime.new(date, ~T[00:00:00], @zone) do
      {:ok, midnight} -> DateTime.shift_zone!(midnight, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _before, first_after} -> DateTime.shift_zone!(first_after, "Etc/UTC")
    end
  end
end
