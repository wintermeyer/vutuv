defmodule Vutuv.CodeStats do
  @moduledoc """
  Cached public statistics for a member's code-forge accounts — the profile's
  "Code" card (issue #922): stars, repositories, followers, languages, last
  activity and top repositories for the listed GitHub / GitLab / Codeberg
  accounts. Neutral facts only, no score.

  The database is the cache: each fetch writes a snapshot map onto the
  account's `social_media_accounts` row (`code_stats` +
  `code_stats_fetched_at`), so rendering never touches the network — the
  profile and its agent-format siblings read the stored snapshot only. A
  missing snapshot (a just-created account: the controller requests it right
  after insert) or one older than 7 days is refreshed in the background by
  `Vutuv.CodeStats.Fetcher`, single-flight per account; an open profile learns
  of the fresh snapshot over `Vutuv.Activity` PubSub
  (`{:code_stats_updated, account_id}` on the owner's topic).

  Failure handling mirrors `Vutuv.SocialFeed` and reuses the same persisted
  fetch-state columns on the row (the two provider sets are disjoint):
  consecutive failures walk the escalating backoff ladder via
  `fetch_retry_at`; a hard error (the account no longer exists, a malformed
  handle) or an exhausted ladder sets `fetch_disabled_at` and the account is
  never asked again — editing the handle resets the state and drops the stale
  snapshot.

  Everything is gated on the `:fetch_code_stats` flag (off in tests, and the
  switch for air-gapped installations — accounts then stay plain links; see
  docs/ADMINS.md). The per-network HTTP/parsing lives in the clients
  (`Vutuv.CodeStats.GitHub` / `GitLab` / `Codeberg`), which only implement
  `fetch_stats/1`.
  """

  import Ecto.Query

  alias Vutuv.Activity
  alias Vutuv.CodeStats.Fetcher
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Repo

  # provider value on the account row => the client module whose fetch_stats/1
  # the fetcher's task runs.
  @providers %{
    "GitHub" => Vutuv.CodeStats.GitHub,
    "GitLab" => Vutuv.CodeStats.GitLab,
    "Codeberg" => Vutuv.CodeStats.Codeberg
  }

  # A snapshot may serve for a week before a profile view refreshes it —
  # deliberately generous: forge stats move slowly, and the stale-by-a-few-
  # days card costs nothing while sparing the forges (and GitHub's 60
  # unauthenticated requests/hour) a lot of traffic.
  @max_age_days 7

  # Consecutive-failure waits: 15 min, 30 min, 1 h, 6 h, 12 h, 24 h, 48 h.
  @backoff_minutes [15, 30, 60, 360, 720, 1440, 2880]

  @doc "Whether fetching code-forge statistics is on at all (off in tests)."
  def enabled?, do: Application.get_env(:vutuv, :fetch_code_stats, true)

  @doc "Whether this provider is a code forge with a stats client."
  def code_provider?(provider), do: is_map_key(@providers, provider)

  @doc """
  Every code-forge account among a user's preloaded accounts, in their order.
  """
  def accounts_of(%{social_media_accounts: accounts}) when is_list(accounts),
    do: Enum.filter(accounts, &code_provider?(&1.provider))

  def accounts_of(_user), do: []

  @doc """
  The accounts whose statistics the profile's "Code" card renders: the
  feature flag is on, the member has not opted out (`show_code_stats?`), and
  a snapshot exists. Renders from the DB only — never the network.
  """
  def visible_accounts(user) do
    if enabled?() and user.show_code_stats? do
      user |> accounts_of() |> Enum.filter(&is_map(&1.code_stats))
    else
      []
    end
  end

  @doc "Whether the snapshot is missing or older than #{@max_age_days} days."
  def stale?(%SocialMediaAccount{code_stats_fetched_at: nil}), do: true

  def stale?(%SocialMediaAccount{code_stats_fetched_at: fetched_at}) do
    DateTime.compare(fetched_at, DateTime.add(DateTime.utc_now(), -@max_age_days, :day)) == :lt
  end

  @doc """
  Whether this account may be fetched right now: not permanently deactivated,
  and not inside a backoff window (`fetch_retry_at` still in the future).
  """
  def fetchable?(%SocialMediaAccount{} = account) do
    is_nil(account.fetch_disabled_at) and retry_due?(account.fetch_retry_at)
  end

  defp retry_due?(nil), do: true
  defp retry_due?(at), do: DateTime.compare(at, DateTime.utc_now()) != :gt

  @doc """
  Requests a background refresh when this account's snapshot is missing or
  older than #{@max_age_days} days. Called right after account create/update
  (the first snapshot) and by profile mounts. A no-op `:ignored` when the
  flag is off, the provider is not a code forge, the snapshot is fresh, or
  the account's fetch state forbids it (backoff window, deactivated).
  """
  def refresh_if_stale(%SocialMediaAccount{} = account) do
    if enabled?() and code_provider?(account.provider) and stale?(account) and
         fetchable?(account) do
      Fetcher.request(account.provider, account.value)
      :ok
    else
      :ignored
    end
  end

  @doc """
  The blocking fetch (run inside the fetcher's task, and directly by tests),
  dispatched to the provider's client: `{:ok, stats_map}` or a classified
  `{:error, :gone | :transient}` — `:gone` is a hard error that deactivates
  the account immediately, `:transient` walks the backoff ladder.
  """
  def fetch_stats(provider, handle), do: Map.fetch!(@providers, provider).fetch_stats(handle)

  @doc """
  Applies a fetch outcome to the account's persisted state: a success writes
  the snapshot (and clears any backoff), then tells the owner's open pages
  over PubSub; failures walk the backoff ladder or deactivate the account,
  exactly like `Vutuv.SocialFeed.record_result/3`. The fetcher's single-flight
  guarantee means there is exactly one writer per account.
  """
  def record_result(provider, handle, {:ok, stats}) when is_map(stats) do
    case get_account(provider, handle) do
      nil ->
        :ok

      account ->
        set_state(account,
          code_stats: stats,
          code_stats_fetched_at: now(),
          fetch_failures: 0,
          fetch_retry_at: nil,
          fetch_disabled_at: nil
        )

        Activity.broadcast(account.user_id, {:code_stats_updated, account.id})
    end
  end

  def record_result(provider, handle, {:error, :gone}), do: disable(provider, handle)

  def record_result(provider, handle, {:error, _transient}) do
    account = get_account(provider, handle)
    failures = ((account && account.fetch_failures) || 0) + 1

    case Enum.at(@backoff_minutes, failures - 1) do
      nil ->
        disable(provider, handle)

      minutes ->
        if account do
          set_state(account,
            fetch_failures: failures,
            fetch_retry_at: DateTime.add(now(), minutes * 60)
          )
        end

        :ok
    end
  end

  # The unique index on (value, provider) makes the handle → row mapping 1:1.
  defp get_account(provider, handle),
    do: Repo.get_by(SocialMediaAccount, provider: provider, value: handle)

  defp disable(provider, handle) do
    case get_account(provider, handle) do
      nil -> :ok
      account -> set_state(account, fetch_disabled_at: now())
    end
  end

  defp set_state(account, set) do
    Repo.update_all(from(a in SocialMediaAccount, where: a.id == ^account.id), set: set)
    :ok
  end

  defp now, do: DateTime.utc_now(:second)
end
