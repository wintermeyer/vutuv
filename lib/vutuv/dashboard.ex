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
  alias Vutuv.Reports

  # How many members each dashboard people list shows at most: the "currently
  # online" and "newest members" cards both link straight to this many profiles.
  @people_list_limit 10

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

    # The per-day counts reuse `Vutuv.Reports`' primitives so the two activity
    # views (this live dashboard and the nightly report) count identically.
    %{
      posts_today: Reports.count_between(Post, today_start, today_end),
      posts_yesterday: Reports.count_between(Post, yesterday_start, yesterday_end),
      last_post_at: latest_inserted_at(Post),
      messages_today: Reports.count_between(Message, today_start, today_end),
      messages_yesterday: Reports.count_between(Message, yesterday_start, yesterday_end),
      last_message_at: latest_inserted_at(Message),
      registrations_today: Reports.count_confirmed_registrations(today_start, today_end),
      registrations_yesterday:
        Reports.count_confirmed_registrations(yesterday_start, yesterday_end)
    }
  end

  @doc """
  How many members confirmed their sign-up so far on the current German
  calendar day (from Berlin 00:00 until now). The single figure behind the
  admin-only "new members today" pill in the app shell
  (`VutuvWeb.ShellLive`), which reads it on its own rather than pulling the
  whole `activity_snapshot/0` for one number. Counts exactly what the
  dashboard's "New members" tile does, so the two can never disagree.
  """
  def registrations_today do
    {day_start, day_end} = BerlinTime.day_bounds_utc(BerlinTime.today())
    Reports.count_confirmed_registrations(day_start, day_end)
  end

  # The newest row's `inserted_at`, or nil for an empty table. Ordered by the
  # UUID v7 primary key, whose embedded creation time makes "highest id" mean
  # "newest" - an index lookup, no `inserted_at` scan.
  defp latest_inserted_at(schema) do
    from(r in schema, order_by: [desc: r.id], limit: 1, select: r.inserted_at)
    |> Repo.one()
  end

  @doc """
  The most recently registered confirmed members, newest first (at most
  `@people_list_limit`). Ordered by the UUID v7 primary key, whose embedded
  timestamp makes "highest id" mean "most recently signed up", so it is an index
  scan with no `inserted_at` sort. Only `email_confirmed?` members count, matching
  the "New members" figure (`Reports.count_confirmed_registrations/2`). Rows carry
  only the columns a listing row renders (`User.listing_fields/0`), so the
  dashboard can link to each profile with its avatar and name.
  """
  def newest_members(limit \\ @people_list_limit) do
    from(u in User, where: u.email_confirmed? == true)
    |> recent_listing(limit)
  end

  @doc """
  Up to `@people_list_limit` of the members named by `online_ids` — the in-memory
  presence set from `VutuvWeb.Presence.online_ids/0` — newest first. Returns `[]`
  for an empty set without touching the database. Rows carry only
  `User.listing_fields/0`, like `newest_members/1`.
  """
  def online_members(online_ids, limit \\ @people_list_limit) do
    case MapSet.to_list(online_ids) do
      [] ->
        []

      ids ->
        from(u in User, where: u.id in ^ids)
        |> recent_listing(limit)
    end
  end

  # Newest-first page of listing-field rows over an already-filtered user query.
  defp recent_listing(query, limit) do
    from(u in query,
      order_by: [desc: u.id],
      limit: ^limit,
      select: struct(u, ^User.listing_fields())
    )
    |> Repo.all()
  end
end
