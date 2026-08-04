defmodule Vutuv.Repo.Migrations.AddSalutationToUsers do
  @moduledoc """
  Replaces the `gender` classification with a `salutation` preference.

  The column only ever fed the German email salutation, so it is renamed to say
  exactly that: `ms` / `mr` / NULL ("no salutation"). Members objected to being
  asked to classify themselves at sign-up, which was never what the value was
  for. The values are locale-neutral because the label is not: an installation
  outside Germany writes "Ms." where ours writes "Frau".

  Expand half of an expand/contract pair: the previous release still reads
  `gender` while this runs, so that column is left in place and untouched here.
  A follow-up deploy drops it.
  """
  use Ecto.Migration

  def up do
    alter table(:users) do
      add(:salutation, :string)
    end

    flush()

    # "other" and NULL both mean "no salutation", which is the column default,
    # so only the two addressable values need copying.
    execute("UPDATE users SET salutation = 'mr' WHERE gender = 'male'")
    execute("UPDATE users SET salutation = 'ms' WHERE gender = 'female'")
  end

  def down do
    alter table(:users) do
      remove(:salutation)
    end
  end
end
