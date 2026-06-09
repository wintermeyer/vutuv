defmodule Vutuv.Repo.Migrations.RemoveDeadGooglePlusSocialMediaAccounts do
  use Ecto.Migration

  # Google+ shut down in 2019. It is no longer one of
  # `Vutuv.Profiles.SocialMediaAccount.accepted_providers/0`, so no new account
  # can pick it, but the legacy data import carried over old "Google+" rows that
  # still render (with a blank value, since there is no display rule for them).
  # Purge them so the dead network disappears from every profile.

  def up do
    execute("DELETE FROM social_media_accounts WHERE provider = 'Google+'")
  end

  def down do
    # The provider is gone for good; the deleted rows cannot be reconstructed.
    :ok
  end
end
