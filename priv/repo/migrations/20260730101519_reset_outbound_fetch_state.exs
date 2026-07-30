defmodule Vutuv.Repo.Migrations.ResetOutboundFetchState do
  use Ecto.Migration

  @moduledoc """
  Clears the remote-fetch backoff state on every social media account.

  v7.95.4 (2026-07-12) replaced `decode_body: false` with the `into:` streaming
  collector in `Vutuv.SocialFeed.Http.get/3`, not realizing Req still decodes a
  JSON-content-typed body afterwards — so every Mastodon/Bluesky feed fetch and
  every GitHub/GitLab/Codeberg stats fetch failed from then on, and each account
  walked the transient-failure ladder toward permanent deactivation
  (`fetch_disabled_at`). The code fix ships with this migration; this repairs
  the poisoned rows so the accounts are fetched again. Accounts that are
  genuinely gone re-disable themselves on their next probe (a hard error
  disables immediately), so a blanket reset is safe.

  Data-only, N-1 compatible: the previous release reads the same columns and
  treats a clean state as "fetchable".
  """

  def up do
    execute("""
    UPDATE social_media_accounts
    SET fetch_failures = 0, fetch_retry_at = NULL, fetch_disabled_at = NULL
    WHERE fetch_failures <> 0
       OR fetch_retry_at IS NOT NULL
       OR fetch_disabled_at IS NOT NULL
    """)
  end

  # The pre-migration state was corrupt bookkeeping; there is nothing to restore.
  def down, do: :ok
end
