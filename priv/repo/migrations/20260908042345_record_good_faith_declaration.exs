defmodule Vutuv.Repo.Migrations.RecordGoodFaithDeclaration do
  use Ecto.Migration

  # One plain nullable column, so the currently deployed release keeps working
  # untouched (N-1): it neither writes nor reads it.
  #
  # A timestamp rather than a boolean, like every other fact this table records
  # about a report (`confirmed_at`, `outcome_notified_at`): the declaration is
  # an act, and nil means "no declaration on file" rather than "declined". Rows
  # filed before this stay nil on purpose — the declaration was demanded of
  # them, but it was never recorded, and writing one in now would invent
  # evidence. See `Vutuv.Moderation.Report` (issue #2069).
  def change do
    alter table(:moderation_reports) do
      add(:good_faith_declared_at, :naive_datetime)
    end
  end
end
