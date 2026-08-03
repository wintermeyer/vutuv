defmodule Vutuv.Repo.Migrations.AddGradeSpanToReferenceChecks do
  @moduledoc """
  Stores the overall grade a review arrived at, instead of re-reading it out of
  the report every time a row is drawn.

  It was parsed on each render from ~10_000 characters of Markdown, on a page
  that lists every Zeugnis a member holds. Saving that work is the small
  reason; the real one is that the value is then settled by the run that
  produced it, so sharpening the parser later cannot silently restate a grade a
  member was already shown beside a Zeugnis they have since sent to an
  employer.

  Nullable, and `Vutuv.References.Check.grade_span/1` still falls back to
  parsing, so a check finished before this column existed keeps its grade
  without a backfill.
  """

  use Ecto.Migration

  def change do
    alter table(:reference_checks) do
      # The label line as the report states it ("1 (Sehr Gut / Hervorragend)",
      # "Note 4 bis 5 (mangelhaft bis ungenügend)"). The parser caps it at 90
      # characters, well inside varchar(255).
      add(:grade_span, :string)
    end
  end
end
