defmodule Vutuv.Dashboard do
  @moduledoc """
  The live operational snapshot behind the admin home dashboard
  (`VutuvWeb.Admin.DashboardLive`): how much was posted and messaged today and
  yesterday, when the last post and message arrived, and how many members
  confirmed their sign-up on each of those two German calendar days.

  `Vutuv.Reports` answers the same "what happened on day X" question for the
  nightly operator email and the `/admin/reports` page. This module is its
  lighter, poll-friendly cousin: it tallies only the handful of figures the
  dashboard shows, so each refresh stays cheap. Both bucket UTC `inserted_at`
  timestamps by the German calendar day (`Vutuv.BerlinTime`).

  The "currently online" figure is deliberately not here: it comes from
  `VutuvWeb.Presence` (in-memory, no database) and the LiveView reads it
  directly.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.BerlinTime
  alias Vutuv.Chat.Message
  alias Vutuv.Posts.Post
  alias Vutuv.Repo

  @doc """
  The dashboard's database figures as a map, computed against the current
  German calendar day. Cheap enough to call on a short refresh interval: a
  handful of day-bucketed counts plus two primary-key-ordered "newest row"
  lookups.
  """
  def activity_snapshot do
    today = BerlinTime.today()
    {today_start, today_end} = BerlinTime.day_bounds_utc(today)
    {yesterday_start, yesterday_end} = BerlinTime.day_bounds_utc(Date.add(today, -1))

    %{
      posts_today: count_between(Post, today_start, today_end),
      posts_yesterday: count_between(Post, yesterday_start, yesterday_end),
      last_post_at: latest_inserted_at(Post),
      messages_today: count_between(Message, today_start, today_end),
      messages_yesterday: count_between(Message, yesterday_start, yesterday_end),
      last_message_at: latest_inserted_at(Message),
      registrations_today: count_confirmed_registrations(today_start, today_end),
      registrations_yesterday: count_confirmed_registrations(yesterday_start, yesterday_end)
    }
  end

  defp count_between(schema, day_start, day_end) do
    from(r in schema, where: r.inserted_at >= ^day_start and r.inserted_at < ^day_end)
    |> Repo.aggregate(:count)
  end

  # Confirmed-by-PIN sign-ups only (mirrors `Vutuv.Reports`): real new members,
  # not the unconfirmed or spam half-registrations the anti-spam gate hides.
  defp count_confirmed_registrations(day_start, day_end) do
    from(u in User,
      where: u.email_confirmed? == true,
      where: u.inserted_at >= ^day_start and u.inserted_at < ^day_end
    )
    |> Repo.aggregate(:count)
  end

  # The newest row's `inserted_at`, or nil for an empty table. Ordered by the
  # UUID v7 primary key, whose embedded creation time makes "highest id" mean
  # "newest" - an index lookup, no `inserted_at` scan.
  defp latest_inserted_at(schema) do
    from(r in schema, order_by: [desc: r.id], limit: 1, select: r.inserted_at)
    |> Repo.one()
  end
end
