defmodule Vutuv.Repo.Migrations.AddKindToEducations do
  use Ecto.Migration

  # Issue #849 (the education twin of #840): education entries carry a
  # category (university | apprenticeship | school) so a CV reader can tell a
  # degree from a Berufsausbildung or general schooling. Additive with a
  # default, so the previous release keeps working (N-1). "university" is the
  # backfill because it fits the overwhelming majority of existing rows on a
  # professional network; the few others are one edit away, and nothing
  # changes visually until a member differentiates.
  def change do
    alter table(:educations) do
      add(:kind, :string, null: false, default: "university")
    end
  end
end
