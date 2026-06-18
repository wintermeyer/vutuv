defmodule Vutuv.Repo.Migrations.AddImageCropsToUsers do
  use Ecto.Migration

  # The user-chosen crop rectangle for the avatar and the cover photo, stored
  # as a compact "x,y,w,h" string of fractions (0..1) of the EXIF-rotated
  # original. nil = no crop chosen (the pipeline's old centered behavior). We
  # persist it so Vutuv.Uploads.Regenerator can re-apply the crop when it
  # re-derives served versions from the kept original after a Spec change —
  # without it, the next format/quality regen would silently un-crop everyone.
  #
  # Two nullable columns, additive only: backward-compatible for the N-1
  # blue/green deploy (the currently deployed release simply ignores them).
  def change do
    alter table(:users) do
      add(:avatar_crop, :string)
      add(:cover_crop, :string)
    end
  end
end
