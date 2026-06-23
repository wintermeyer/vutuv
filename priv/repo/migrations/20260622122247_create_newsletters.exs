defmodule Vutuv.Repo.Migrations.CreateNewsletters do
  use Ecto.Migration

  def change do
    # Admin-authored broadcast emails ("Rundbrief"). A newsletter is composed and
    # saved as a draft, test-mailed to a single address, then broadcast to every
    # eligible member. Status moves draft -> sending -> sent (sending is the lock
    # that stops a second broadcast). author_id keeps history if the admin is later
    # deleted (nilify), so the audit trail outlives the account.
    create table(:newsletters) do
      add(:subject, :string, null: false)
      add(:body, :text, null: false)
      add(:status, :string, null: false, default: "draft")
      add(:sent_at, :naive_datetime)
      add(:recipient_count, :integer, null: false, default: 0)
      add(:author_id, references(:users, on_delete: :nilify_all))
      timestamps()
    end

    create(index(:newsletters, [:status]))

    # The delivery protocol: one row per address a newsletter was sent to, so the
    # admin can see exactly when which email went out. kind = test | broadcast,
    # status = sent | suppressed | error (the chokepoint may drop a bounced
    # address). user_id is the recipient member (nil for a test to an arbitrary
    # address); it nilifies if that member is later deleted so the log survives.
    create table(:newsletter_deliveries) do
      add(:newsletter_id, references(:newsletters, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, on_delete: :nilify_all))
      add(:email, :string, null: false)
      add(:kind, :string, null: false)
      add(:status, :string, null: false)
      timestamps()
    end

    create(index(:newsletter_deliveries, [:newsletter_id, :inserted_at]))
    create(index(:newsletter_deliveries, [:user_id]))

    # Opt-out flag for the newsletter. Default true (an opt-out, like a classic
    # service newsletter): existing members are subscribed, and every newsletter
    # carries a one-click unsubscribe that flips this off. Distinct from the
    # event-driven notification prefs, which default off. Added here as a plain
    # nullable-with-default column, so it is backward compatible in one deploy.
    alter table(:users) do
      add(:newsletter_emails?, :boolean, null: false, default: true)
    end
  end
end
