defmodule Vutuv.Repo.Migrations.AddGalleryFill do
  @moduledoc """
  Whether a multi-photo post's bento tiles are FILLED by their photos
  (object-cover, cropping them to the tile) — the author's explicit choice.
  The default is false: the mosaic shows whole photos, letterboxed inside
  their tiles (Stefan, 2026-07-30: "im Bento immer die vollen Fotos"). This
  deliberately flips the rendering of existing posts too — the old
  always-cropping behaviour becomes the opt-in.

  Additive with defaults, N-1 safe (the running release ignores both).
  """

  use Ecto.Migration

  def change do
    alter table(:posts) do
      add(:gallery_fill?, :boolean, default: false, null: false)
    end

    alter table(:post_drafts) do
      add(:fill?, :boolean, default: false, null: false)
    end
  end
end
