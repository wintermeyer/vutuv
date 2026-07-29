defmodule Vutuv.Repo.Migrations.AddPostImageCropAndGalleryLayout do
  @moduledoc """
  Three additive nullable columns, N-1 safe (the running release ignores them):

    * `post_images.crop` — the author's ratio crop as `"x,y,w,h"` fractions of
      the EXIF-rotated original (`Vutuv.Uploads.Crop`), persisted so the
      Regenerator re-applies it. Bounded by `Vutuv.Uploads.Crop.normalize/1`
      (four short decimal fractions plus commas, ~27 bytes), so varchar(255)
      is ample.
    * `posts.gallery_layout` — the author's chosen bento arrangement, one of
      the short names in `Vutuv.Posts.GalleryLayout`; NULL = automatic.
    * `post_drafts.layout` — the same choice while it is still a draft.
  """

  use Ecto.Migration

  def change do
    alter table(:post_images) do
      add(:crop, :string)
    end

    alter table(:posts) do
      add(:gallery_layout, :string)
    end

    alter table(:post_drafts) do
      add(:layout, :string)
    end
  end
end
