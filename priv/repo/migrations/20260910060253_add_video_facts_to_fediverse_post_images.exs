defmodule Vutuv.Repo.Migrations.AddVideoFactsToFediversePostImages do
  use Ecto.Migration

  # What a reader needs to know BEFORE tapping a clip that streams from
  # somebody else's server (issue #1914). All three come out of the
  # ActivityPub attachment itself, which every instance measured fills in even
  # where it sends no cover: `duration` as an ISO-8601 string ("PT73.2S"),
  # `width`/`height` as the clip's own — the existing width/height columns hold
  # the COVER's, which is a Mastodon thumbnail a fraction of the size.
  #
  # `byte_size` is the one fact the attachment does not carry, so it is filled
  # from a HEAD on the file and stays null when that answer never comes. Plain
  # additions, all nullable: N-1 compatible in one deploy.
  def change do
    alter table(:fediverse_post_images) do
      add(:duration_ms, :integer)
      add(:byte_size, :bigint)
      add(:video_width, :integer)
      add(:video_height, :integer)
    end
  end
end
