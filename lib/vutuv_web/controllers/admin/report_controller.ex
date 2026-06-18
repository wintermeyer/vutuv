defmodule VutuvWeb.Admin.ReportController do
  @moduledoc """
  The admin daily-activity dashboard: confirmed-by-PIN new registrations and
  the posts, reposts, likes and bookmarks created on a German calendar day
  (`Vutuv.Reports`). The `?date=YYYY-MM-DD` query parameter is the time
  machine, any past or current day can be inspected; it defaults to yesterday,
  the day the overnight email reports on. A future date is clamped to today.
  """

  use VutuvWeb, :controller

  alias Vutuv.BerlinTime
  alias Vutuv.Reports

  def index(conn, params) do
    today = BerlinTime.today()
    date = params |> Map.get("date") |> parse_date() |> clamp(today)

    render(conn, "index.html",
      page_title: gettext("Daily report for %{day}", day: Date.to_iso8601(date)),
      report: Reports.daily(date),
      date: date,
      today: today
    )
  end

  defp parse_date(nil), do: nil

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  # A missing or unparsable ?date falls back to yesterday, what the nightly
  # mail covers.
  defp clamp(nil, today), do: Date.add(today, -1)

  # There is nothing to count for a day that has not happened yet.
  defp clamp(date, today) do
    if Date.compare(date, today) == :gt, do: today, else: date
  end
end
