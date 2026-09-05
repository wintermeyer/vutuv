defmodule Vutuv.Repo.Migrations.AddFeedPageSizeToUsers do
  use Ecto.Migration

  # How many posts one feed page holds for this member: what an arrival draws,
  # what "Load more" adds, and what a source switch or an opened calendar day
  # asks for. Set from the control under the feed itself or on /settings/feed.
  #
  # Nullable and without a default, like every `Vutuv.Prefs` column: NULL means
  # "inherit", so the installation default (10) stays distinguishable from a
  # member who chose 10. A plain additive column, so the currently deployed
  # release keeps working unchanged (N-1).
  def change do
    alter table(:users) do
      add(:feed_page_size, :integer)
    end
  end
end
