defmodule Vutuv.RemoteFetch.Backoff do
  @moduledoc """
  The persisted fetch-state / backoff machinery shared by the two remote-account
  fetchers: the inline social feeds (`Vutuv.SocialFeed`) and the code-forge
  statistics (`Vutuv.CodeStats`). Both walk the same escalating retry ladder on
  the shared `social_media_accounts` fetch-state columns (`fetch_failures`,
  `fetch_retry_at`, `fetch_disabled_at`), so this module owns that ladder and the
  row bookkeeping while each context keeps only its success-path specifics (the
  social feed's ETS cache TTL, the code stats' snapshot write + PubSub).

  The two provider sets are disjoint (Mastodon/Bluesky vs GitHub/GitLab/Codeberg)
  and the unique index on `(value, provider)` makes each handle -> row mapping
  1:1, so a failure recorded for one context never touches the other's rows.

  Consecutive failures wait 15 min, 30 min, 1 h, 6 h, 12 h, 24 h, 48 h; one more
  failure after the last rung (or a hard error) sets `fetch_disabled_at` and the
  account is never asked again. Editing the handle resets the state (the schema
  changeset clears these columns).
  """

  import Ecto.Query

  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Repo

  # Consecutive-failure waits: 15 min, 30 min, 1 h, 6 h, 12 h, 24 h, 48 h.
  @backoff_minutes [15, 30, 60, 360, 720, 1440, 2880]

  @doc """
  Whether this account may be fetched right now: not permanently deactivated,
  and not inside a backoff window (`fetch_retry_at` still in the future).
  """
  def fetchable?(%SocialMediaAccount{} = account) do
    is_nil(account.fetch_disabled_at) and retry_due?(account.fetch_retry_at)
  end

  defp retry_due?(nil), do: true
  defp retry_due?(at), do: DateTime.compare(at, DateTime.utc_now()) != :gt

  @doc "The account row for a provider/handle, or nil (the mapping is 1:1)."
  def get_account(provider, handle),
    do: Repo.get_by(SocialMediaAccount, provider: provider, value: handle)

  @doc "Sets the given fetch-state columns on the account row. Returns `:ok`."
  def set_state(%SocialMediaAccount{} = account, set) do
    Repo.update_all(from(a in SocialMediaAccount, where: a.id == ^account.id), set: set)
    :ok
  end

  @doc """
  Permanently deactivates the account (a hard error, or an exhausted ladder) by
  stamping `fetch_disabled_at`. A no-op when the row is gone. Returns `:ok`.
  """
  def disable(provider, handle) do
    case get_account(provider, handle) do
      nil -> :ok
      account -> set_state(account, fetch_disabled_at: now())
    end
  end

  @doc """
  Records one transient failure: walks the account to the next rung of the
  backoff ladder (`{:retry_in_minutes, m}`), or disables it once the ladder is
  exhausted (`:disabled`). A missing row still classifies but persists nothing.
  """
  def record_transient(provider, handle) do
    account = get_account(provider, handle)
    failures = ((account && account.fetch_failures) || 0) + 1

    case Enum.at(@backoff_minutes, failures - 1) do
      nil ->
        disable(provider, handle)
        :disabled

      minutes ->
        if account do
          set_state(account,
            fetch_failures: failures,
            fetch_retry_at: DateTime.add(now(), minutes * 60)
          )
        end

        {:retry_in_minutes, minutes}
    end
  end

  @doc "The current UTC second, for the fetch-state timestamps."
  def now, do: DateTime.utc_now(:second)
end
