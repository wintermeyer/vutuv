defmodule Vutuv.Repo.Migrations.AddPhotoPostFields do
  @moduledoc """
  Photo posts (issue #1104): a per-post license, per-photo captions, the
  whitelisted camera facts parsed at upload time, and the two per-photo
  opt-ins (original download, camera panel).

  Plain additions only — every column is new and defaulted, so the currently
  deployed release keeps running against the migrated schema (the N-1 rule).

  Deliberately **no GPS columns**: the coordinates are never parsed and never
  stored. `has_gps` records only *that* the upload carried a location, which
  is what lets the composer warn an author before they hand out the exact
  file (`Vutuv.Uploads.Exif`).
  """

  use Ecto.Migration

  def change do
    alter table(:posts) do
      # The photo license the whole post is published under, from the fixed
      # `Vutuv.Posts.PhotoLicense` vocabulary. "arr" (all rights reserved) is
      # the safe default and what every existing post gets.
      add(:license, :string, null: false, default: "arr")
    end

    alter table(:users) do
      # The member's last license pick, offered as the default on their next
      # photo post. NULL = never picked one, so the shipped default applies.
      add(:default_post_license, :string)
    end

    alter table(:post_images) do
      # Shown to everyone under the photo. `alt` stays what it was: the
      # description for people who cannot see the picture.
      add(:caption, :text)

      # The whitelisted camera facts, parsed once at upload. Kept as display
      # primitives (the photographic notation f/2.8, 1/200 s, ISO 400, 50 mm
      # reads the same in every locale) so rendering needs no re-derivation.
      add(:camera, :string)
      add(:lens, :string)
      add(:focal_length, :string)
      add(:aperture, :string)
      add(:shutter, :string)
      add(:iso, :integer)
      add(:taken_at, :naive_datetime)

      # Whether the upload carried location data. Never the coordinates —
      # only the fact, so the composer can warn about the exact-file download.
      add(:has_gps, :boolean, null: false, default: false)

      # The two per-photo opt-ins, both off by default.
      add(:show_camera_info, :boolean, null: false, default: false)
      add(:download_original, :boolean, null: false, default: false)
      # false = the cleaned copy (metadata stripped, pixels untouched);
      # true = the byte-identical upload. Only read while download_original.
      add(:download_exact, :boolean, null: false, default: false)
    end
  end
end
