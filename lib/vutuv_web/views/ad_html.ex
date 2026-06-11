defmodule VutuvWeb.AdHTML do
  @moduledoc false
  use VutuvWeb, :html

  alias Vutuv.Ads
  alias Vutuv.Ads.Ad

  embed_templates("../templates/ad/*")

  @doc """
  The availability calendar of the booking form: one grid per month of the
  booking window (`Vutuv.Ads.first_bookable_day/0` to `last_bookable_day/0`),
  Monday-first, each day tagged `:free`, `:booked` or `:unavailable` (outside
  the window). The template renders free days as radio buttons - the day is
  picked on the calendar, not typed.
  """
  def calendar_months do
    today = Ads.today()
    first = Ads.first_bookable_day()
    last = Ads.last_bookable_day()
    booked = Ads.booked_days()

    # One grid per month the window touches, however wide the context says
    # the window is (today's month through last_bookable_day's month).
    month_span = last.year * 12 + last.month - (today.year * 12 + today.month)

    for offset <- 0..month_span do
      month_start = today |> Date.shift(month: offset) |> Date.beginning_of_month()

      %{
        title: "#{month_name(month_start.month)} #{month_start.year}",
        weeks: month_weeks(month_start, first, last, booked)
      }
    end
  end

  # Monday-aligned weeks of the month, nil-padded at both ends.
  defp month_weeks(month_start, first, last, booked) do
    lead = Date.day_of_week(month_start) - 1

    days =
      for day <- Date.range(month_start, Date.end_of_month(month_start)) do
        {day, day_state(day, first, last, booked)}
      end

    Enum.chunk_every(List.duplicate(nil, lead) ++ days, 7, 7, List.duplicate(nil, 6))
  end

  defp day_state(day, first, last, booked) do
    cond do
      MapSet.member?(booked, day) -> :booked
      Date.compare(day, first) == :lt or Date.compare(day, last) == :gt -> :unavailable
      true -> :free
    end
  end

  @doc "Monday-first weekday initials for the calendar header."
  def weekday_initials do
    [
      gettext("Mo"),
      gettext("Tu"),
      gettext("We"),
      gettext("Th"),
      gettext("Fr"),
      gettext("Sa"),
      gettext("Su")
    ]
  end

  defp month_name(1), do: gettext("January")
  defp month_name(2), do: gettext("February")
  defp month_name(3), do: gettext("March")
  defp month_name(4), do: gettext("April")
  defp month_name(5), do: gettext("May")
  defp month_name(6), do: gettext("June")
  defp month_name(7), do: gettext("July")
  defp month_name(8), do: gettext("August")
  defp month_name(9), do: gettext("September")
  defp month_name(10), do: gettext("October")
  defp month_name(11), do: gettext("November")
  defp month_name(12), do: gettext("December")

  def status_label(%Ad{approved_at: nil}), do: gettext("Waiting for approval")
  def status_label(%Ad{}), do: gettext("Approved")

  @doc """
  The approval-state pill shown on the member dashboard and the admin review
  page. Green once approved; neutral while the review is pending (amber is
  reserved for moderation notices).
  """
  attr(:ad, Ad, required: true)

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-bold",
      if(@ad.approved_at,
        do: "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-200",
        else: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"
      )
    ]}>
      {status_label(@ad)}
    </span>
    """
  end
end
