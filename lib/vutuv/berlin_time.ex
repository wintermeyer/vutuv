defmodule Vutuv.BerlinTime do
  @moduledoc """
  "What day is it in Germany?" without a timezone database.

  vutuv carries no `tzdata` dependency, so the one offset it needs - Europe/
  Berlin - is computed from the fixed EU daylight-saving rule: CEST (UTC+2)
  between the last Sunday of March, 01:00 UTC, and the last Sunday of
  October, 01:00 UTC; CET (UTC+1) otherwise. That rule has been stable since
  1996, so hardcoding it beats pulling in a whole timezone database for a
  single offset.

  This is the single source for the German calendar day. The daily ad
  rotation (`Vutuv.Ads`) books and serves ads by it; the profile age display
  (`VutuvWeb.UserHelpers.age/1`) rolls a member's age over at German local
  midnight rather than at UTC midnight.
  """

  @doc "Today as a German calendar day (Europe/Berlin)."
  def today, do: date(DateTime.utc_now())

  @doc "The current Europe/Berlin wall-clock time as a `NaiveDateTime`."
  def now, do: naive(DateTime.utc_now())

  @doc "A UTC instant as Europe/Berlin wall-clock time (a `NaiveDateTime`)."
  def naive(%DateTime{} = utc) do
    offset_hours = if summer_time?(utc), do: 2, else: 1

    utc
    |> DateTime.add(offset_hours * 3600, :second)
    |> DateTime.to_naive()
  end

  @doc "The German calendar date of a UTC instant."
  def date(%DateTime{} = utc) do
    offset_hours = if summer_time?(utc), do: 2, else: 1

    utc
    |> DateTime.add(offset_hours * 3600, :second)
    |> DateTime.to_date()
  end

  @doc """
  The UTC half-open instant range `[start, finish)` that spans a whole German
  calendar day, as `NaiveDateTime`s (the type Ecto stores `inserted_at` in).
  Use it to bucket UTC timestamps by German calendar day, e.g. counting a
  day's registrations and posts (`Vutuv.Reports`).

  The offset is the one in effect at Berlin-local midday of `date` (CET +1h
  in winter, CEST +2h in summer). On the two yearly DST-switch days that can
  misplace rows landing in the one-hour window right after local midnight,
  which is immaterial to a daily tally.
  """
  def day_bounds_utc(%Date{} = date) do
    {local_midnight_utc(date), local_midnight_utc(Date.add(date, 1))}
  end

  @doc """
  The next Europe/Berlin local midnight (00:00) strictly after `utc`, as a UTC
  `DateTime`. Used to schedule work at the German day boundary - the
  `Vutuv.DayClock` refreshes every open page's Berlin-dated post timestamps at
  00:00, so a post shown as bare "09:50 Uhr" rolls over to "Gestern, 09:50 Uhr".

  Since `utc` always falls inside its own Berlin day, tomorrow's Berlin midnight
  is always in the future, so no extra guard is needed. The offset is taken at
  the target midnight's midday (the same DST caveat `day_bounds_utc/1` carries):
  on the two switch nights a year the boundary can land an hour off, which a
  midnight fan-out timer does not care about.
  """
  def next_midnight_utc(%DateTime{} = utc \\ DateTime.utc_now()) do
    utc
    |> date()
    |> Date.add(1)
    |> local_midnight_as_utc()
  end

  # Berlin-local 00:00 of `date`, expressed as a UTC NaiveDateTime.
  defp local_midnight_utc(date), do: date |> local_midnight_as_utc() |> DateTime.to_naive()

  # Berlin-local 00:00 of `date`, expressed as a UTC DateTime.
  defp local_midnight_as_utc(date) do
    midday_utc = DateTime.new!(date, ~T[12:00:00], "Etc/UTC")
    offset_hours = if summer_time?(midday_utc), do: 2, else: 1

    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.add(-offset_hours * 3600, :second)
  end

  defp summer_time?(utc) do
    dst_start = last_sunday_at_one_utc(utc.year, 3)
    dst_end = last_sunday_at_one_utc(utc.year, 10)

    DateTime.compare(utc, dst_start) != :lt and DateTime.compare(utc, dst_end) == :lt
  end

  defp last_sunday_at_one_utc(year, month) do
    last_of_month = Date.new!(year, month, Date.days_in_month(Date.new!(year, month, 1)))
    # day_of_week: Monday = 1 ... Sunday = 7; rem/2 turns Sunday into 0.
    last_sunday = Date.add(last_of_month, -rem(Date.day_of_week(last_of_month), 7))
    DateTime.new!(last_sunday, ~T[01:00:00], "Etc/UTC")
  end
end
