defmodule Vutuv.Repo.Migrations.AddCoverPhotoToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Mirrors :avatar: stores the original upload's file name verbatim; the
      # on-disk versions live under covers/<id>/ (see Vutuv.Cover).
      add(:cover_photo, :string)
    end
  end
end
