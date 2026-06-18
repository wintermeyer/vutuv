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

  @doc "The German calendar date of a UTC instant."
  def date(%DateTime{} = utc) do
    offset_hours = if summer_time?(utc), do: 2, else: 1

    utc
    |> DateTime.add(offset_hours * 3600, :second)
    |> DateTime.to_date()
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
