defmodule Vutuv.Repo.Migrations.AddEmploymentStatusToUsers do
  use Ecto.Migration

  # The member's job-availability signal (issue #870): nil = not specified
  # (the default for everyone, no badge), "open" = employed but open to
  # offers, "looking" = actively looking for a new role. A plain nullable
  # column, so this is a backward-compatible one-step add (the previous
  # release simply ignores it). The value set is small and constrained in the
  # changeset (validate_inclusion), so a varchar(255) is more than enough.
  def change do
    alter table(:users) do
      add :employment_status, :string
    end
  end
end
