defmodule Vutuv.Repo.Migrations.AddShowMastodonFeedToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Per-member switch for the inline Mastodon posts on their profile's
      # Social Media card. Default on so a listed Mastodon account shows its
      # latest public posts from day one; members opt out on the Privacy
      # settings page. Additive nullable-with-default column, N-1 safe.
      add(:show_mastodon_feed?, :boolean, default: true, null: false)
    end
  end
end
