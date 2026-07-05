defmodule Vutuv.Repo.Migrations.AddPositionToLanguages do
  use Ecto.Migration

  # Spoken languages (issue #894) gain a member-defined display order so the
  # first entry can express the language they prefer to be contacted in. The
  # column is nullable so this stays N-1 backward compatible: the currently
  # deployed release neither writes nor reads `position` and keeps working
  # while the migration runs. The new release writes it on create / reorder and
  # orders by it (NULLs last, then id), so legacy or mid-deploy rows fall back
  # to their creation order until reordered.
  #
  # Backfill seeds each member's existing languages with 1..n in *today's*
  # proficiency order (native, then the CEFR scale C2..A1, then alphabetically
  # by code — the old `Language.ordered/1` sort), so nobody's list reshuffles on
  # deploy; it simply becomes editable from that starting point.
  def up do
    alter table(:languages) do
      add(:position, :integer)
    end

    execute("""
    UPDATE languages AS l
    SET position = ranked.rn
    FROM (
      SELECT id, ROW_NUMBER() OVER (
        PARTITION BY user_id
        ORDER BY
          array_position(ARRAY['native','c2','c1','b2','b1','a2','a1'], proficiency),
          language_code
      ) AS rn
      FROM languages
    ) AS ranked
    WHERE l.id = ranked.id
    """)
  end

  def down do
    alter table(:languages) do
      remove(:position)
    end
  end
end
