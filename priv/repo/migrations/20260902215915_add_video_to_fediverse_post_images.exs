defmodule Vutuv.Repo.Migrations.AddVideoToFediversePostImages do
  use Ecto.Migration

  # A video attached to a post from another network (issue #1914). The row
  # stays in the pictures table because it is drawn like one — a cover with a
  # play glyph — and goes through the same fetch and the same AI gate for that
  # cover. What differs is recorded here: the declared media type (nil for a
  # picture, as every row before this was) and where the cover comes from,
  # since the file at `source_uri` is the clip itself and is never downloaded
  # (up to 99 MB per post on Mastodon; the reader's browser plays it straight
  # from the other server). Two nullable columns: N-1 safe.
  def change do
    alter table(:fediverse_post_images) do
      add(:media_type, :string)
      add(:poster_uri, :text)
    end
  end
end
