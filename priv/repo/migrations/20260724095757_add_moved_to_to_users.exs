defmodule Vutuv.Repo.Migrations.AddMovedToToUsers do
  use Ecto.Migration

  # Fediverse account migration, half 2 (issue #986): where a member redirected
  # their Fediverse followers *to*. `moved_to` is the target actor URI rendered
  # as `movedTo` on the actor document (the redirect a remote server honors);
  # `moved_at` stamps the last Move broadcast, so a re-move cooldown can hold.
  # Both nullable and additive, so the migration is N-1 backward compatible.
  def change do
    alter table(:users) do
      add(:moved_to, :text)
      add(:moved_at, :naive_datetime)
    end
  end
end
