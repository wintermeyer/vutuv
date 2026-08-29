defmodule VutuvWeb.Live.FeedTimeTravel do
  @moduledoc """
  Opening one calendar day in `/feed` — the arithmetic behind
  `VutuvWeb.PostLive.FeedCalendar`.

  ## Why this is nearly free

  `Vutuv.FeedPage.paginate/3` already walks the merged feed by a cursor, and
  every source applies its `at` as `inserted_at <= ^at`. Travelling is
  therefore not a new query shape at all: it is a **synthetic first cursor**
  handed to the same `Vutuv.Posts.feed_page/2` a normal mount calls. "Load
  more" chains from there without knowing anything happened, and every
  visibility, block, language and content filter keeps applying, because none
  of them were bypassed.

  ## A day is a window

  The cursor carries a **lower** bound too (`:since`), which is what makes
  "show me Tuesday" mean Tuesday rather than Tuesday and all of history under
  it. That bound rides in the cursor rather than beside it precisely so it
  survives pagination: `Vutuv.FeedPage` carries it from page to page, so
  pressing "Load more" inside a day stops at the day's own edge.

  A day of `nil` means *now*, and now is the only state that takes live
  arrivals. There is no window on a day that has not happened.

  ## The reader's calendar, not the server's

  Every boundary here is computed in the reader's own zone
  (`Vutuv.ViewerClock`), so a member in Auckland opens their Tuesday and not
  Berlin's. What is stored and handed to the query is always UTC naive,
  matching every `inserted_at` in the app.
  """

  alias Vutuv.ViewerClock

  @doc "Now, in the same shape every `inserted_at` carries."
  def now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  @doc """
  The window that shows one whole calendar day: its first and last instant in
  the reader's zone, as the UTC naive pair the cursor carries.
  """
  defdelegate day_window(date), to: ViewerClock

  @doc """
  The feed cursor for one whole day, or `nil` for no day (the live present).

  Today is bounded at **now** rather than at a midnight that has not happened
  yet, and a future day has no window at all.
  """
  def day_cursor(nil), do: nil

  def day_cursor(%Date{} = date) do
    {first, last} = day_window(date)
    now = now()

    if NaiveDateTime.compare(first, now) == :gt do
      nil
    else
      %{at: min_naive(last, now), ids: [], since: first}
    end
  end

  @doc """
  The grid a month calendar draws: whole weeks, Monday first, each cell a date
  plus whether it belongs to the month being shown.

  Always six rows of seven. A month that would fit in five still gets six, so
  the calendar does not change height as the reader pages through months and
  push the rail cards below it up and down.
  """
  def month_grid(%Date{} = month) do
    first = Date.beginning_of_month(month)
    start = Date.add(first, -(Date.day_of_week(first) - 1))

    Enum.map(0..41, fn offset ->
      date = Date.add(start, offset)
      %{date: date, in_month?: date.month == month.month and date.year == month.year}
    end)
  end

  @doc "The month a date sits in (this month, for `nil`)."
  def month_of(nil), do: Date.beginning_of_month(ViewerClock.today())
  def month_of(%Date{} = date), do: Date.beginning_of_month(date)

  @doc """
  Steps a shown month by `n` months (or `n * 12` for the year arrows), never
  past the current month: there is nothing to show in the future, and a
  calendar that pages into it is offering days that cannot be clicked.
  """
  def shift_month(%Date{} = month, n) when is_integer(n) do
    shifted = month |> Date.beginning_of_month() |> add_months(n)
    this_month = Date.beginning_of_month(ViewerClock.today())

    if Date.compare(shifted, this_month) == :gt, do: this_month, else: shifted
  end

  @doc "Whether a date can be opened at all (today or earlier)."
  def reachable?(%Date{} = date), do: Date.compare(date, ViewerClock.today()) != :gt

  @doc "Reads a `YYYY-MM-DD` phx-value back into a date."
  def parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  def parse_date(_other), do: :error

  defp min_naive(a, b), do: if(NaiveDateTime.compare(a, b) == :lt, do: a, else: b)

  # `Date.add/2` walks days, so month arithmetic has to normalise the day of the
  # month itself: stepping back a month from the 31st has to land on the 28th in
  # February rather than overflowing into March.
  defp add_months(%Date{} = date, n) do
    months = date.year * 12 + (date.month - 1) + n
    year = div(months, 12)
    month = rem(months, 12) + 1

    Date.new!(year, month, min(date.day, Date.days_in_month(Date.new!(year, month, 1))))
  end
end
