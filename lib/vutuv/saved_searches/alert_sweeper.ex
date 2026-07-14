defmodule Vutuv.SavedSearches.AlertSweeper do
  @moduledoc """
  The nightly saved-search alert sweeper (issue #935, Jobs 8/9). Once per Berlin
  calendar day it batches **one** digest e-mail per member: every one of their
  notifying saved searches (`Vutuv.SavedSearches`) is re-run for matches created
  since its high-water mark, and the searches with new matches are listed with
  up to five results each and a link to the full list.

  Daily searches are swept every day; weekly ones only on
  `SavedSearches.weekly_weekday/0` (Monday). New-match detection is the
  `last_notified_at` high-water mark, advanced to the sweep cutoff afterwards, so
  a match is mailed at most once. People matches honour blocks and the #928/#938
  job-search visibility of the *recipient*; the members' own private salary
  expectation never rides along.

  Scheduling mirrors `Vutuv.Jobs.Sweeper` (a single `Process.send_after` aimed at
  the next Berlin-local time, re-armed each day), a few minutes after it so a
  posting that expires at 00:10 is already off the board. Off in tests
  (`:saved_search_alerts`); a test calls `sweep/1` directly.
  """

  use GenServer

  require Logger

  alias Vutuv.Accounts
  alias Vutuv.BerlinTime
  alias Vutuv.Jobs
  alias Vutuv.Notifications.Emailer
  alias Vutuv.SavedSearches
  alias Vutuv.Search
  alias Vutuv.Social

  @trigger_minute 20
  @per_search_limit 5

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_next()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:run, state) do
    sweep(BerlinTime.today())
    schedule_next()
    {:noreply, state}
  end

  @doc """
  Runs one sweep for `today` (Berlin): mails each member with new matches a
  single digest and advances every evaluated search's high-water mark. Returns
  the number of members mailed, so a test can assert on it.
  """
  def sweep(today \\ BerlinTime.today()) do
    cutoff = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    today
    |> SavedSearches.due_searches()
    |> Enum.group_by(& &1.user_id)
    |> Enum.reduce(0, fn {_user_id, searches}, mailed ->
      if process_member(searches, cutoff), do: mailed + 1, else: mailed
    end)
  end

  # Evaluate one member's due searches, mail the non-empty ones as a single
  # digest, and advance every evaluated search's mark. Returns whether a mail
  # went out.
  defp process_member(searches, cutoff) do
    user = hd(searches).user
    blocked = Social.blocked_user_ids(user.id)

    sections =
      searches
      |> Enum.map(&{&1, matches(&1, user, cutoff, blocked)})
      |> Enum.reject(fn {_search, entries} -> entries == [] end)

    mailed? = sections != [] and user.saved_search_emails? and deliver(user, sections)

    Enum.each(searches, &SavedSearches.mark_swept(&1, cutoff))
    mailed?
  end

  defp matches(%{kind: :jobs} = search, user, cutoff, _blocked) do
    filters = Jobs.board_filters(URI.decode_query(search.query), user)

    Jobs.new_board_postings(user, filters,
      since: SavedSearches.baseline(search),
      until: cutoff,
      limit: @per_search_limit
    )
  end

  defp matches(%{kind: :people} = search, user, cutoff, blocked) do
    params = URI.decode_query(search.query)

    Search.new_matching_people(params["q"] || "", user,
      since: SavedSearches.baseline(search),
      until: cutoff,
      exact: params["exact"] == "1",
      blocked_ids: blocked,
      limit: @per_search_limit
    )
  end

  # Returns true when a mail was enqueued (there is an address to send to).
  defp deliver(user, sections) do
    case Accounts.first_email_value(user) do
      nil ->
        false

      address ->
        Emailer.deliver_async(fn ->
          user |> Emailer.saved_search_alert_email(address, sections) |> Emailer.deliver()
        end)

        Logger.info("SavedSearches.AlertSweeper mailed #{length(sections)} sections to a member")
        true
    end
  end

  defp schedule_next do
    Process.send_after(self(), :run, ms_until_next_trigger())
  end

  defp ms_until_next_trigger do
    now = DateTime.to_naive(DateTime.utc_now())
    today = BerlinTime.today()
    today_trigger = trigger_instant(today)

    target =
      if NaiveDateTime.compare(now, today_trigger) == :lt,
        do: today_trigger,
        else: trigger_instant(Date.add(today, 1))

    max(NaiveDateTime.diff(target, now, :millisecond), 0)
  end

  defp trigger_instant(date) do
    {midnight_utc, _day_end} = BerlinTime.day_bounds_utc(date)
    NaiveDateTime.add(midnight_utc, @trigger_minute * 60, :second)
  end
end
