defmodule Vutuv.Repo.Migrations.CreateWebPushSubscriptions do
  use Ecto.Migration

  # One browser's Web Push subscription for this installation's own installed
  # app (issue #1729) — the sibling of `mastodon_push_subscriptions`, which
  # keys on an access token a member's own phone does not have.
  #
  # Unique on the ENDPOINT, not on the member: an endpoint is a browser
  # profile's address at its push service, so the same phone signed in as
  # somebody else has to move the row rather than add a second one, which would
  # leave the previous member's notifications going to a device they signed out
  # of.
  #
  # `endpoint` is `:text` and not a varchar: it is a URL on somebody else's
  # push service and is not ours to bound — the same reasoning as
  # `fediverse_followers.inbox_uri`, and the same 22001 trap, since nothing
  # user-facing writes this column. The btree unique index over it is what
  # makes the length load-bearing — an entry may not exceed ~2704 bytes, and
  # Postgres RAISES 54000 rather than truncating — so
  # `Vutuv.WebPush.Validations.validate_endpoint/1` caps it at 2048, the same
  # bound the fediverse URI sources take.
  #
  # Additions only, so the previous release is untouched.
  def change do
    create table(:web_push_subscriptions) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)

      add(:endpoint, :text, null: false)
      add(:p256dh, :string, null: false)
      add(:auth, :string, null: false)

      # "Safari on iPhone": what the settings list calls this device, from
      # `Vutuv.Sessions.device_summary/1` — the same wording the device list
      # under Sign-in & security already uses.
      add(:device, :string)

      timestamps()
    end

    create(unique_index(:web_push_subscriptions, [:endpoint]))
    create(index(:web_push_subscriptions, [:user_id]))
  end
end
