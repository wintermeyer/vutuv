defmodule Vutuv.Repo.Migrations.AddProfileUrlToFediverseRemoteAccounts do
  use Ecto.Migration

  def change do
    alter table(:fediverse_remote_accounts) do
      # The account's page for a human reader (the actor document's `url`),
      # which is not always the actor id and never reliably `https://host/@user`:
      # Friendica serves `/profile/doris`, PeerTube `/accounts/…`. `text` like
      # its sibling `actor_uri`, because the remote server decides its length;
      # the changeset caps it at 2048 bytes.
      add(:profile_url, :text)
    end

    # Every rendered body with a `@user@host` now looks its accounts up by host
    # and `lower(handle)` (`Vutuv.Fediverse.remote_web_urls/1`, and the card's
    # `remote_account_by_address/1`). The host index alone reads every account
    # of a big server to find one. The expression must stay `lower(handle)`,
    # exactly as the queries write it, or the planner ignores the index.
    create(index(:fediverse_remote_accounts, ["host", "lower(handle)"]))
  end
end
