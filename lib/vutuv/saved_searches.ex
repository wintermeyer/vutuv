defmodule Vutuv.SavedSearches do
  @moduledoc """
  Saved searches with e-mail alerts (issue #935, Jobs 8/9).

  A member captures the current filters on the `/jobs` board or the `/search`
  people page as a `SavedSearch` row (the page's raw URL query string), picks an
  alert cadence (`none`/`daily`/`weekly`), and the nightly
  `Vutuv.SavedSearches.AlertSweeper` mails them the new matches. New-result
  detection is a high-water mark (`last_notified_at`): only entities created
  after it count, so a mail never repeats an old result — the same pattern as
  the DM unread-notification cutoff.

  This module owns the rows (create with the per-member cap, list/edit/delete,
  the sweeper's due-set and mark helpers) and the small presentation helpers
  (`results_url/1`, `summary_segments/1`). The matching itself lives with the
  data it queries: `Vutuv.Jobs.new_board_postings/3` and
  `Vutuv.Search.new_matching_people/3`.
  """

  import Ecto.Query
  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Accounts.User
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Repo
  alias Vutuv.SavedSearches.SavedSearch
  alias Vutuv.UUIDv7

  @default_max_per_member 10

  @doc """
  The per-member cap on saved searches (a plain anti-abuse ceiling the operator
  sets, not a member preference). Configurable via
  `config :vutuv, :saved_searches, max_per_member: N` (env
  `SAVED_SEARCHES_MAX_PER_MEMBER`); defaults to #{@default_max_per_member}.
  """
  def max_per_member do
    :vutuv
    |> Application.get_env(:saved_searches, [])
    |> Keyword.get(:max_per_member, @default_max_per_member)
  end

  # --- read -----------------------------------------------------------------

  @doc "A member's saved searches, newest first (for the settings list)."
  def list_for_user(%User{id: user_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    entries =
      SavedSearch
      |> where([s], s.user_id == ^user_id)
      |> order_by([s], desc: s.inserted_at, desc: s.id)
      |> limit(^(limit + 1))
      |> offset(^offset)
      |> Repo.all()

    {shown, more?} =
      if length(entries) > limit, do: {Enum.take(entries, limit), true}, else: {entries, false}

    %{entries: shown, more?: more?, next_offset: offset + length(shown)}
  end

  @doc "How many saved searches a member has (for the cap and the settings hub)."
  def count_for_user(%User{id: user_id}) do
    Repo.aggregate(from(s in SavedSearch, where: s.user_id == ^user_id), :count, :id)
  end

  @doc "Whether the member has any saved search (the settings block is hidden until then)."
  def any_for_user?(%User{id: user_id}) do
    Repo.exists?(from(s in SavedSearch, where: s.user_id == ^user_id))
  end

  @doc "Fetches one of the member's own saved searches by id, or nil."
  def get_for_user(%User{id: user_id}, id) do
    case UUIDv7.cast_or_nil(id) do
      nil -> nil
      uuid -> Repo.one(from(s in SavedSearch, where: s.id == ^uuid and s.user_id == ^user_id))
    end
  end

  # --- write ----------------------------------------------------------------

  @doc """
  Saves a search for `user`. Enforces the per-member cap and, when the cadence
  is not `:none`, stamps `last_notified_at` to now so the first sweep only
  reports matches newer than the moment alerts were switched on (never the whole
  backlog). Returns `{:ok, saved_search}`, `{:error, changeset}`, or
  `{:error, :quota}` when the member is at the cap.
  """
  def create(%User{} = user, attrs) do
    if count_for_user(user) >= max_per_member() do
      {:error, :quota}
    else
      %SavedSearch{user_id: user.id}
      |> SavedSearch.changeset(attrs)
      |> stamp_high_water_on_enable(:none)
      |> Repo.insert()
    end
  end

  @doc """
  Changes only the alert cadence of one of the member's searches. Turning alerts
  **on** (from `:none`) resets the high-water mark to now, so enabling a
  long-dormant search doesn't flood the member with its whole backlog; switching
  between `:daily` and `:weekly` keeps the mark so no window is skipped.
  """
  def update_notify(%SavedSearch{} = saved_search, attrs) do
    saved_search
    |> SavedSearch.notify_changeset(attrs)
    |> stamp_high_water_on_enable(saved_search.notify)
    |> Repo.update()
  end

  @doc "Deletes a saved search."
  def delete(%SavedSearch{} = saved_search), do: Repo.delete(saved_search)

  # When the cadence moves from :none to a notifying value, (re)start the
  # high-water mark at now. Any other transition leaves it untouched.
  defp stamp_high_water_on_enable(changeset, previous_notify) do
    notify = Ecto.Changeset.get_field(changeset, :notify)

    if notify != :none and previous_notify == :none do
      Ecto.Changeset.put_change(changeset, :last_notified_at, now())
    else
      changeset
    end
  end

  # --- sweeper support ------------------------------------------------------

  # Weekly alerts collect on a fixed weekday (Monday), so a member's weekly
  # digest always lands the same day.
  @weekly_weekday 1

  @doc "The ISO weekday (1 = Monday) weekly digests are sent on."
  def weekly_weekday, do: @weekly_weekday

  @doc """
  Every notifying search due on `today` (Berlin), preloaded with `:user` and
  ordered by member so the sweeper can batch one mail per member. Daily searches
  are always due; weekly ones only on `weekly_weekday/0`.
  """
  def due_searches(today) do
    weekly_day? = Date.day_of_week(today) == @weekly_weekday
    cadences = if weekly_day?, do: [:daily, :weekly], else: [:daily]

    SavedSearch
    |> where([s], s.notify in ^cadences)
    |> order_by([s], asc: s.user_id, asc: s.inserted_at)
    |> preload(:user)
    |> Repo.all()
  end

  @doc "The baseline timestamp for 'new since': the high-water mark, or the save time."
  def baseline(%SavedSearch{last_notified_at: nil, inserted_at: inserted_at}), do: inserted_at
  def baseline(%SavedSearch{last_notified_at: at}), do: at

  @doc """
  Marks a search swept at `cutoff`: advances both `last_run_at` (when it was
  last evaluated) and the `last_notified_at` high-water mark. Every evaluated
  due search advances the mark — whether the member was mailed, had no new
  matches, or has opted out — so a match is accounted for exactly once and never
  reappears in a later mail (the same best-effort advance the DM sweeper makes).
  """
  def mark_swept(%SavedSearch{} = saved_search, cutoff) do
    from(s in SavedSearch, where: s.id == ^saved_search.id)
    |> Repo.update_all(set: [last_run_at: cutoff, last_notified_at: cutoff])

    :ok
  end

  # --- per-search disable (the mail's one-click link) -----------------------

  @doc "Switches one search's alerts off (the per-search unsubscribe link target)."
  def disable(%SavedSearch{} = saved_search) do
    saved_search
    |> Ecto.Changeset.change(notify: :none)
    |> Repo.update()
  end

  @doc "Fetches a saved search by id for the disable link (no owner scope), or nil."
  def get(id) do
    case UUIDv7.cast_or_nil(id) do
      nil -> nil
      uuid -> Repo.get(SavedSearch, uuid)
    end
  end

  # --- presentation ---------------------------------------------------------

  @doc """
  The page URL that re-runs a saved search ("run now" / the mail's "see all"
  link): the board or people page with the stored filters.
  """
  def results_url(%SavedSearch{kind: :jobs, query: query}), do: with_query("/jobs", query)
  def results_url(%SavedSearch{kind: :people, query: query}), do: with_query("/search", query)

  defp with_query(path, query) do
    case String.trim(query || "") do
      "" -> path
      q -> path <> "?" <> q
    end
  end

  @doc """
  A short, mostly-data summary of a saved search for the settings list and the
  alert mail heading — a list of segment strings the caller joins. The salary
  filter is deliberately **omitted**: a member's private salary expectation
  (#928) must never surface in a mail, so no salary figure is ever rendered
  here, even though the sweeper still applies the filter.
  """
  def summary_segments(%SavedSearch{kind: kind, query: query}) do
    params = URI.decode_query(query || "")

    kind
    |> segment_keys()
    |> Enum.flat_map(&segment(&1, params))
  end

  defp segment_keys(:jobs), do: ~w(q tag workplace employment near country my_tags)
  defp segment_keys(:people), do: ~w(q tag city status)

  defp segment("q", %{"q" => q}) when q != "", do: [q]
  defp segment("tag", %{"tag" => t}) when t != "", do: ["#" <> t]
  defp segment("city", %{"city" => c}) when c != "", do: [c]

  defp segment("near", params) do
    case params["near"] do
      near when is_binary(near) and near != "" ->
        radius = params["radius"]
        if radius in [nil, "", "0"], do: [near], else: ["#{near} (#{radius} km)"]

      _ ->
        []
    end
  end

  defp segment("country", %{"country" => c}) when c != "", do: [Vutuv.Countries.name(c)]
  defp segment("workplace", %{"workplace" => w}) when w != "", do: [workplace_label(w)]
  defp segment("employment", %{"employment" => e}) when e != "", do: [employment_label(e)]

  defp segment("status", %{"status" => s}) when s in ["open", "looking"],
    do: [User.employment_status_label(s)]

  defp segment("my_tags", %{"my_tags" => v}) when v in ["1", "true", "on"],
    do: [gettext("matches my tags")]

  defp segment(_key, _params), do: []

  defp workplace_label(value) do
    case Enum.find(JobPosting.workplace_types(), &(Atom.to_string(&1) == value)) do
      nil -> value
      type -> JobPosting.workplace_type_label(type)
    end
  end

  defp employment_label(value) do
    case Enum.find(JobPosting.employment_types(), &(Atom.to_string(&1) == value)) do
      nil -> value
      type -> JobPosting.employment_type_label(type)
    end
  end

  defp now, do: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
end
