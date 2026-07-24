defmodule Vutuv.Repo.Migrations.AddAlsoKnownAsToUsers do
  use Ecto.Migration

  # The Fediverse accounts a member is migrating *from* (issue #986, half 1).
  # Rendered as `alsoKnownAs` on the actor document, this is what a remote
  # server (Mastodon) checks before it moves a member's followers *to* their
  # vutuv account. A text array so a long actor URI can never raise 22001, and
  # a plain additive column so the migration is N-1 backward compatible.
  def change do
    alter table(:users) do
      add(:also_known_as, {:array, :text}, null: false, default: [])
    end
  end
end
