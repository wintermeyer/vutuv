defmodule Vutuv.Repo.Migrations.AddFeedSourceAtToUsers do
  use Ecto.Migration

  @moduledoc """
  When the member last moved between the feed's source tabs — the second half
  of `feed_source`, and the anchor a reconnecting feed dates its unseen dot
  from (`VutuvWeb.PostLive.Feed.restore_unseen/2`).

  The dot on the tab you are not on lived only in the socket, so every LiveView
  rejoin — a locked phone, a throttled background tab, a wifi handover, a
  deploy — dropped it without the page reloading, which read as the dot
  expiring on its own after a couple of minutes. Written only by
  `Vutuv.Posts.remember_feed_filter/2`, beside the tab it names, and NULL for
  everyone who has never pressed one. N-1 safe: a pure nullable addition.
  """

  def change do
    alter table(:users) do
      add(:feed_source_at, :naive_datetime)
    end
  end
end
