defmodule Vutuv.SocialFeed do
  @moduledoc """
  The inline social feeds on the profile's "Social media posts" card: the
  latest public posts of a member's listed Mastodon and Bluesky accounts,
  merged into one card.

  This module is the provider-agnostic half. It knows which providers can be
  fetched (`@providers` maps the `social_media_accounts.provider` value to its
  client module), gates each behind its own feature flag, and owns the
  persisted fetch state on the account row. The per-network HTTP/parsing lives
  in the clients (`Vutuv.Mastodon`, `Vutuv.Bluesky`), which only implement
  `fetch_posts/1`; the single-flight cache (`Vutuv.SocialFeed.Cache`) owns the
  fetch tasks — pages talk to `cached_posts/1` and `request_posts/1` only.

  Struggling servers get room to breathe. Each fetch failure walks the account
  up the backoff ladder (15 min to 48 h) via the fetch state persisted on its
  `social_media_accounts` row — persisted in the DB, not ETS, so backoff and
  deactivation survive the blue/green deploys. One more failure after the last
  rung, or a hard error (the account no longer exists, a malformed handle, a
  host resolving to our own network), sets `fetch_disabled_at` and the account
  is never asked again; editing the handle resets the state. The ladder and the
  row bookkeeping live in the shared `Vutuv.RemoteFetch.Backoff` (the code-forge
  stats fetcher walks the same one).
  """

  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.RemoteFetch.Backoff
  alias Vutuv.SocialFeed.Cache

  # provider value on the account row => the client module whose fetch_posts/1
  # the cache's fetch task runs.
  @providers %{"Mastodon" => Vutuv.Mastodon, "Bluesky" => Vutuv.Bluesky}

  # Per-provider feature flags (both off in tests; tests flip them per-test
  # and stub HTTP via the provider's req-options seam).
  @flags %{"Mastodon" => :fetch_mastodon_posts, "Bluesky" => :fetch_bluesky_posts}

  @doc "Whether fetching this provider's posts is on at all (off in tests)."
  def enabled?(provider) when is_map_key(@flags, provider),
    do: Application.get_env(:vutuv, Map.fetch!(@flags, provider), true)

  # A non-feed provider (a code-forge account, LinkedIn, …) has no feed flag, so
  # fetching its posts is simply off — request_posts/1 then degrades to :ignored
  # instead of raising a FunctionClauseError.
  def enabled?(_provider), do: false

  @doc """
  Every feed-capable account among a user's preloaded accounts, in their
  order — the accounts of the providers listed above whose feature flag is on.
  """
  def accounts_of(%{social_media_accounts: accounts}) when is_list(accounts) do
    Enum.filter(accounts, &(is_map_key(@providers, &1.provider) and enabled?(&1.provider)))
  end

  def accounts_of(_user), do: []

  @doc """
  Whether this account may be fetched right now: not permanently deactivated,
  and not inside a backoff window (`fetch_retry_at` still in the future).
  """
  defdelegate fetchable?(account), to: Backoff

  @doc """
  The cached posts for an account: `{:ok, %Feed{}}`, `{:error, reason}`, or
  `:miss`. A synchronous ETS read, never the network — safe on every render
  path including the disconnected one.
  """
  def cached_posts(%SocialMediaAccount{} = account),
    do: Cache.lookup({account.provider, account.value})

  @doc """
  Asks the cache to deliver this account's posts to the calling process as a
  `{:social_feed_posts, provider, handle, result}` message — either straight
  from the cache or after the (deduplicated) fetch. A no-op `:ignored` when
  the provider's feature flag is off or the account's fetch state forbids it
  (backoff window, deactivated).
  """
  def request_posts(%SocialMediaAccount{} = account) do
    if enabled?(account.provider) and fetchable?(account) do
      Cache.request(account.provider, account.value, self())
      :ok
    else
      :ignored
    end
  end

  @doc """
  The blocking fetch (run inside the cache's task, and directly by tests),
  dispatched to the provider's client: `{:ok, %Feed{}}` or a classified
  `{:error, :gone | :transient}` — `:gone` is a hard error that deactivates
  the account immediately, `:transient` walks the backoff ladder.
  """
  def fetch_posts(provider, handle), do: Map.fetch!(@providers, provider).fetch_posts(handle)

  @doc """
  Applies a fetch outcome to the account's persisted fetch state and returns
  what the cache should do with the entry: `:reset` (success — normal TTL),
  `{:retry_in_minutes, m}` (transient failure — next rung of the backoff
  ladder), or `:disabled` (hard error or ladder exhausted — never again).
  Called by the cache after every fetch; the single-flight guarantee means
  there is exactly one writer per account.
  """
  def record_result(provider, handle, {:ok, _posts}) do
    reset_fetch_state(provider, handle)
    :reset
  end

  def record_result(provider, handle, {:error, :gone}) do
    Backoff.disable(provider, handle)
    :disabled
  end

  def record_result(provider, handle, {:error, _transient}),
    do: Backoff.record_transient(provider, handle)

  # Success clears the backoff only when there is something to clear, sparing a
  # write on the common already-clean row.
  defp reset_fetch_state(provider, handle) do
    account = Backoff.get_account(provider, handle)

    if account &&
         (account.fetch_failures > 0 || account.fetch_retry_at || account.fetch_disabled_at) do
      Backoff.set_state(account, fetch_failures: 0, fetch_retry_at: nil, fetch_disabled_at: nil)
    end

    :ok
  end
end
