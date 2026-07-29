defmodule Vutuv.Repo.Migrations.AddVerificationToSocialMediaAccounts do
  use Ecto.Migration

  # Verified social-media handles: a member proves a listed account is really
  # theirs and it earns the same small emerald mark a verified webpage link
  # gets. Only Bluesky implements a proof today (its profile bio must carry
  # the member's vutuv profile URL — the network has no rel=me), but the
  # columns are deliberately provider-agnostic, so a second network is one
  # clause in Vutuv.Profiles.SocialAccountVerification, not another migration.
  #
  # No verification_token twin of the urls table: the proof is the profile URL
  # itself, exactly like the rel_me method, which ignores that token.
  #
  # All columns nullable -> a plain, N-1-safe single-deploy addition.
  def change do
    alter table(:social_media_accounts) do
      add(:verification_method, :string)
      add(:verified_at, :naive_datetime)
      add(:last_checked_at, :naive_datetime)
      add(:grace_deadline_at, :naive_datetime)
    end
  end
end
