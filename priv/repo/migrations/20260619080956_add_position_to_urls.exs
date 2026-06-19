defmodule Vutuv.Repo.Migrations.AddPositionToUrls do
  use Ecto.Migration

  # Links (the `urls` table) gain a user-defined display order. The column is
  # nullable so this stays N-1 backward compatible: the currently deployed
  # release neither writes nor reads `position` and keeps working while the
  # migration runs. The new release writes it on create / reorder and orders by
  # it (NULLs last, then id), so legacy or mid-deploy rows simply sort by their
  # creation order until they are reordered.
  #
  # Backfill seeds each member's existing links with 1..n in creation order
  # (UUID v7 ids sort by creation time), so today's implicit order survives the
  # switch and stays editable.
  def up do
    alter table(:urls) do
      add(:position, :integer)
    end

    execute("""
    UPDATE urls AS u
    SET position = ranked.rn
    FROM (
      SELECT id, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY id) AS rn
      FROM urls
    ) AS ranked
    WHERE u.id = ranked.id
    """)
  end

  def down do
    alter table(:urls) do
      remove(:position)
    end
  end
end
