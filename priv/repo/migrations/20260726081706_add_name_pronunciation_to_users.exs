defmodule Vutuv.Repo.Migrations.AddNamePronunciationToUsers do
  use Ecto.Migration

  # How to say this member's name out loud (issue #1112) — the one thing a
  # written name cannot carry, and what makes a first phone call go right.
  # Free text in a plain varchar(255): almost nobody writes IPA, and the member
  # knows best whether "SHTEH-fahn" or "rhymes with 'a fan'" helps a caller more.
  #
  # Nullable, and empty on nearly every profile by design: the profile renders
  # the line only when it is filled, so an untouched account looks exactly as it
  # did. A plain column addition, so it is N-1 compatible on its own.
  def change do
    alter table(:users) do
      add(:name_pronunciation, :string)
    end
  end
end
