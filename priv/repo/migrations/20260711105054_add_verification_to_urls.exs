defmodule Vutuv.Repo.Migrations.AddVerificationToUrls do
  use Ecto.Migration

  # Verified personal-webpage links: a member proves a profile link is really
  # their page (rel=me back-link, or the company-style DNS / well-known domain
  # proof) and it earns a small verified mark. Per-link, independent state; no
  # uniqueness constraint (two members may each prove the same shared host).
  # All columns nullable -> a plain, N-1-safe single-deploy addition.
  def change do
    alter table(:urls) do
      add(:verification_method, :string)
      add(:verification_token, :string)
      add(:verified_at, :naive_datetime)
      add(:last_checked_at, :naive_datetime)
      add(:grace_deadline_at, :naive_datetime)
    end
  end
end
