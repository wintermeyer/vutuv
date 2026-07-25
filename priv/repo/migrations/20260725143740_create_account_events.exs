defmodule Vutuv.Repo.Migrations.CreateAccountEvents do
  use Ecto.Migration

  # The append-only account-activity log (issue #1087): one row per
  # security-relevant or identity-relevant change, so a member (and support) can
  # answer "when did this change, and was that me?".
  #
  # Purely additive, so it is N-1 compatible: the currently deployed release
  # neither reads nor writes this table.
  def change do
    create table(:account_events) do
      # Whose account the event is about. Cascades with the account: the log is
      # personal data and goes when the member goes.
      add(:user_id, references(:users, on_delete: :delete_all), null: false)

      # Who performed it, when that was somebody else (an admin acting for
      # support). NULL means the member themselves or the system, which is what
      # makes "that wasn't me" answerable at a glance.
      add(:actor_user_id, references(:users, on_delete: :nilify_all))

      add(:kind, :string, null: false)

      # How the member proved it was them: passkey / authenticator / list_code /
      # pin / session / admin. NULL when the change needed no confirmation.
      add(:factor, :string)

      add(:ip_address, :string)

      # The COARSE device summary ("Chrome on macOS"), never the raw
      # User-Agent - see Vutuv.Sessions.device_summary/1.
      add(:device, :string)

      # A small per-kind map. Never holds a secret and never holds the value of
      # a private field; Vutuv.AccountEvents whitelists the keys per kind.
      add(:details, :map, null: false, default: %{})

      # Microsecond resolution so two changes in the same second still have an
      # order - support has to be able to pin a change down to the second.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # The member's own page: their events, newest first.
    create(index(:account_events, [:user_id, "inserted_at DESC"]))

    # The admin page across all members, and the retention sweep.
    create(index(:account_events, ["inserted_at DESC"]))

    # The kind filter on both pages.
    create(index(:account_events, [:kind]))
  end
end
