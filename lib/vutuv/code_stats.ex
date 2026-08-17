defmodule Vutuv.CodeStats do
  @moduledoc """
  Cached public statistics for a member's code-forge accounts — the profile's
  "Code" card (issue #922): stars, repositories, followers, languages, last
  activity and top repositories for the listed GitHub / GitLab / Codeberg and
  **self-hosted Gitea / Forgejo** accounts. Neutral facts only, no score.

  A self-hosted account (issue #1504) is the one whose instance the member
  names themselves, so it is also the one that has to earn its place:
  `verify_instance/1` asks that instance before the entry is accepted at all —
  see its doc for why that check is the whole answer to "then anyone can type
  anything".

  The database is the cache: each fetch writes a snapshot map onto the
  account's `social_media_accounts` row (`code_stats` +
  `code_stats_fetched_at`), so rendering never touches the network — the
  profile and its agent-format siblings read the stored snapshot only. A
  missing snapshot (a just-created account: the controller requests it right
  after insert) or one older than 7 days is refreshed in the background by
  `Vutuv.CodeStats.Fetcher`, single-flight per account; an open profile learns
  of the fresh snapshot over `Vutuv.Activity` PubSub
  (`{:code_stats_updated, account_id}` on the owner's topic).

  Failure handling shares the `Vutuv.RemoteFetch.Backoff` ladder with
  `Vutuv.SocialFeed` and reuses the same persisted fetch-state columns on the
  row (the two provider sets are disjoint): consecutive failures walk the
  escalating backoff ladder via `fetch_retry_at`; a hard error (the account no
  longer exists, a malformed handle) or an exhausted ladder sets
  `fetch_disabled_at` and the account is never asked again — editing the handle
  resets the state and drops the stale snapshot.

  Everything is gated on the `:fetch_code_stats` flag (off in tests, and the
  switch for air-gapped installations — accounts then stay plain links; see
  docs/ADMINS.md). The per-network HTTP/parsing lives in the clients
  (`Vutuv.CodeStats.GitHub` / `GitLab` / `Codeberg`), which only implement
  `fetch_stats/1`.
  """

  import Ecto.Changeset, only: [add_error: 3, get_change: 2, get_field: 2]

  alias Vutuv.Activity
  alias Vutuv.CodeStats.Fetcher
  alias Vutuv.CodeStats.Forgejo
  alias Vutuv.CodeStats.Snapshot
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.RemoteFetch.Backoff

  # provider value on the account row => the client module whose fetch_stats/1
  # the fetcher's task runs. Gitea and Forgejo share one client: they speak the
  # same API, and the instance rides in the value (`name@git.example.com`).
  @providers %{
    "GitHub" => Vutuv.CodeStats.GitHub,
    "GitLab" => Vutuv.CodeStats.GitLab,
    "Codeberg" => Vutuv.CodeStats.Codeberg,
    "Gitea" => Vutuv.CodeStats.Forgejo,
    "Forgejo" => Vutuv.CodeStats.Forgejo
  }

  # A snapshot may serve for a week before a profile view refreshes it —
  # deliberately generous: forge stats move slowly, and the stale-by-a-few-
  # days card costs nothing while sparing the forges (and GitHub's 60
  # unauthenticated requests/hour) a lot of traffic.
  @max_age_days 7

  # Activity within this window is the normal case and stays quiet; only an
  # account quiet for longer gets a "Last active" line on the card/docs.
  @dormant_after_days 28

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

  @doc """
  The "last active" date to surface for a snapshot's `last_active_at`
  ISO-8601 string, or nil while the account is recently active. The line is
  a **dormancy signal, not a live ticker**: pushes within the last
  #{@dormant_after_days} days are the normal case and stay quiet; only an
  account that has been quiet for longer gets its last-activity date shown
  (on the card and in the human-readable agent formats — JSON/XML always
  carry the raw timestamp).
  """
  def dormant_since(last_active_at) when is_binary(last_active_at) do
    with %DateTime{} = dt <- Snapshot.datetime(last_active_at),
         :lt <-
           DateTime.compare(dt, DateTime.add(DateTime.utc_now(), -@dormant_after_days, :day)) do
      DateTime.to_date(dt)
    else
      _ -> nil
    end
  end

  def dormant_since(_), do: nil

  @doc "Whether the snapshot is missing or older than #{@max_age_days} days."
  def stale?(%SocialMediaAccount{code_stats_fetched_at: nil}), do: true

  def stale?(%SocialMediaAccount{code_stats_fetched_at: fetched_at}) do
    DateTime.compare(fetched_at, DateTime.add(DateTime.utc_now(), -@max_age_days, :day)) == :lt
  end

  @doc """
  Whether this account may be fetched right now: not permanently deactivated,
  and not inside a backoff window (`fetch_retry_at` still in the future).
  """
  defdelegate fetchable?(account), to: Backoff

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
  Whether this changeset carries a **new** self-hosted forge address, i.e. one
  `verify_instance/1` would put a question to the instance about. The caller
  asks first so it can spend a rate-limit slot only on a save that really
  reaches out (see `VutuvWeb.RateLimit.check_instance_probe/2`).
  """
  def instance_probe_needed?(%Ecto.Changeset{} = changeset) do
    changeset.valid? and enabled?() and
      SocialMediaAccount.self_hosted_provider?(get_field(changeset, :provider)) and
      is_binary(get_change(changeset, :value))
  end

  @doc """
  The admission check for a self-hosted forge account (issue #1504): the
  instance must answer for that username, or the entry is refused.

  This is what keeps "self-hosted" from meaning "type anything". github.com and
  codeberg.org vouch for their own handles by existing; an address a member
  invented does not, so the entry has to earn its place by being *there* — and
  the same request that proves it is the one that later fills the "Code" card,
  so nothing is spent on the check.

  A refusal is worded by which of the two things went wrong, because they ask
  different things of the member: `:gone` (the instance answered, and has no
  such user) is a verdict they can act on, `:transient` (we could not ask) is
  not one and must never be reported as though it were.

  A no-op when the flag is off — an air-gapped installation cannot ask, so it
  takes the entry at its word and renders it as a plain link, exactly as it
  does for GitHub.
  """
  def verify_instance(%Ecto.Changeset{} = changeset) do
    if instance_probe_needed?(changeset) do
      probe_instance(changeset, get_change(changeset, :value))
    else
      changeset
    end
  end

  defp probe_instance(changeset, value) do
    case Forgejo.fetch_user(value) do
      {:ok, _user} ->
        changeset

      {:error, :gone} ->
        add_error(
          changeset,
          :value,
          "We could not find this account on that instance. Please check the address."
        )

      {:error, _transient} ->
        add_error(
          changeset,
          :value,
          "That instance did not answer. Please try again in a moment."
        )
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
    case Backoff.get_account(provider, handle) do
      nil ->
        :ok

      account ->
        Backoff.set_state(account,
          code_stats: stats,
          code_stats_fetched_at: Backoff.now(),
          fetch_failures: 0,
          fetch_retry_at: nil,
          fetch_disabled_at: nil
        )

        Activity.broadcast(account.user_id, {:code_stats_updated, account.id})
    end
  end

  def record_result(provider, handle, {:error, :gone}), do: Backoff.disable(provider, handle)

  def record_result(provider, handle, {:error, _transient}) do
    # The transient ladder walks in the shared backoff; the fetcher ignores the
    # return, so `:ok` keeps the context's own success/gone paths returning `:ok`.
    Backoff.record_transient(provider, handle)
    :ok
  end
end
