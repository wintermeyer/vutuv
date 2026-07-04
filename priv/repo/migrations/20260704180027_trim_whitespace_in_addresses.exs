defmodule Vutuv.Repo.Migrations.TrimWhitespaceInAddresses do
  use Ecto.Migration

  # Backfill: strip leading/trailing whitespace already stored in address
  # fields (a stray space made the CV and other surfaces join a zip and city
  # into e.g. "50679  Köln"). The changeset now trims on every save; this
  # cleans the rows written before that. Data-only, N-1 safe: the currently
  # deployed release reads the trimmed values unchanged. regexp_replace with
  # `\s` matches String.trim's whitespace class; NULLIF collapses a value
  # left blank to NULL, mirroring the changeset's trim_or_nil.
  @fields ~w(description line_1 line_2 line_3 line_4 zip_code city state country)a

  def up do
    for field <- @fields do
      col = to_string(field)

      execute("""
      UPDATE addresses
      SET #{col} = NULLIF(regexp_replace(#{col}, '^\\s+|\\s+$', '', 'g'), '')
      WHERE #{col} IS DISTINCT FROM NULLIF(regexp_replace(#{col}, '^\\s+|\\s+$', '', 'g'), '')
      """)
    end
  end

  def down do
    # Whitespace normalization is not reversible.
    :ok
  end
end
