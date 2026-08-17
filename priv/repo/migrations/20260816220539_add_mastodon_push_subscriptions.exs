defmodule Vutuv.Repo.Migrations.AddMastodonPushSubscriptions do
  use Ecto.Migration

  # One subscription per access token: Mastodon's own model, and the right one
  # here too — a member with two phones has two tokens, and revoking one app
  # must take its pushes with it, which the CASCADE below does.
  #
  # Additions only, so the previous release is untouched.
  def change do
    create table(:mastodon_push_subscriptions) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:api_token_id, references(:api_tokens, on_delete: :delete_all), null: false)

      # A push endpoint is a URL on somebody else's service and is not ours to
      # bound, so `:text` rather than a varchar — the same reasoning as
      # `fediverse_followers.inbox_uri`.
      add(:endpoint, :text, null: false)
      add(:p256dh, :string, null: false)
      add(:auth, :string, null: false)

      # Which notification kinds this device wants, as Mastodon's alerts map.
      add(:alerts, :map, null: false, default: %{})

      timestamps()
    end

    create(unique_index(:mastodon_push_subscriptions, [:api_token_id]))
    create(index(:mastodon_push_subscriptions, [:user_id]))
  end
end
