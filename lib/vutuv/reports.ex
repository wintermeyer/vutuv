defmodule Vutuv.Reports do
  @moduledoc """
  Basic daily activity reporting for the site operator.

  `daily/1` tallies a single German calendar day (`Vutuv.BerlinTime`):
  confirmed-by-PIN new registrations and the number of posts, reposts, likes
  and bookmarks created that day. The admin reports page
  (`VutuvWeb.Admin.ReportController`) renders any past day on demand;
  `Vutuv.Reports.DailyReporter` mails the previous day's report just after
  midnight, skipping all-zero days.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.BerlinTime
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Posts.{Post, PostBookmark, PostLike, PostRepost}
  alias Vutuv.Repo
  alias Vutuv.Reports.DailyReport

  @doc """
  The activity tally for a single German calendar `date`. Counts rows whose
  UTC `inserted_at` falls inside that Berlin day
  (`BerlinTime.day_bounds_utc/1`).

  `registrations` counts only accounts that proved control of their email by
  entering a login PIN (`email_confirmed?`), so it tracks real new members,
  not the half-finished or spam sign-ups the anti-spam gate keeps hidden.
  """
  def daily(%Date{} = date) do
    {day_start, day_end} = BerlinTime.day_bounds_utc(date)

    %DailyReport{
      date: date,
      registrations: count_confirmed_registrations(day_start, day_end),
      posts: count_between(Post, day_start, day_end),
      reposts: count_between(PostRepost, day_start, day_end),
      likes: count_between(PostLike, day_start, day_end),
      bookmarks: count_between(PostBookmark, day_start, day_end)
    }
  end

  @doc """
  Builds the report for `date` and mails it to the operator through the
  `Vutuv.Notifications.Emailer` chokepoint, unless every metric is zero, in
  which case nothing is sent and `:skipped` is returned. Returns
  `{:ok, report}` when a mail goes out.
  """
  def deliver_daily_email(%Date{} = date) do
    report = daily(date)

    if DailyReport.all_zero?(report) do
      :skipped
    else
      report |> Emailer.daily_report_email() |> Emailer.deliver()
      {:ok, report}
    end
  end

  defp count_confirmed_registrations(day_start, day_end) do
    from(u in User,
      where: u.email_confirmed? == true,
      where: u.inserted_at >= ^day_start and u.inserted_at < ^day_end
    )
    |> Repo.aggregate(:count)
  end

  defp count_between(schema, day_start, day_end) do
    from(r in schema, where: r.inserted_at >= ^day_start and r.inserted_at < ^day_end)
    |> Repo.aggregate(:count)
  end
end
