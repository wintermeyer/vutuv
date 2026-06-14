defmodule Vutuv.Repo.Migrations.RenameClarityAttributeNames do
  use Ecto.Migration

  # Clarify several attribute names whose old labels did not say what they hold
  # (the worst offender: `users.activated?`, which for the imported legacy
  # membership read `false` for tens of thousands of real members). Pure column
  # renames; safe because version-6 ships as a single planned-downtime deploy.
  def change do
    rename(table(:users), :activated?, to: :email_confirmed?)

    # login_pins: `value` is the flow payload (e.g. the new address mid email
    # change), `created_at` is the mint/expiry anchor (nulled to expire, distinct
    # from `inserted_at`), `pin` is the peppered HMAC hash (parallels pin_salt).
    rename(table(:login_pins), :value, to: :payload)
    rename(table(:login_pins), :created_at, to: :minted_at)
    rename(table(:login_pins), :pin, to: :pin_hash)

    # Boolean ?-suffix convention + drop the non-idiomatic is_ prefix.
    rename(table(:urls), :broken, to: :broken?)
    rename(table(:webhook_subscriptions), :active, to: :active?)
    rename(table(:moderation_severances), :had_connection, to: :had_connection?)

    rename(table(:moderation_severances), :had_follow_reporter_to_owner,
      to: :had_follow_reporter_to_owner?
    )

    rename(table(:moderation_severances), :had_follow_owner_to_reporter,
      to: :had_follow_owner_to_reporter?
    )

    rename(table(:search_queries), :is_email?, to: :email?)
  end
end
