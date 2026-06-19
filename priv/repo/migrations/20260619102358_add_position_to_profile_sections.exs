defmodule Vutuv.Repo.Migrations.AddPositionToProfileSections do
  use Ecto.Migration

  # Phone numbers, addresses, social media accounts and email addresses gain a
  # user-defined display order, the same one the `urls` table already got. The
  # column is nullable so this stays N-1 backward compatible: the currently
  # deployed release neither writes nor reads `position` and keeps working while
  # the migration runs. The new release writes it on create / reorder and orders
  # by it (NULLs last, then id), so legacy or mid-deploy rows simply sort by
  # their creation order until they are reordered.
  #
  # The backfill seeds each member's existing rows with 1..n in creation order
  # (UUID v7 ids sort by creation time), so today's implicit order survives the
  # switch and stays editable.
  @tables ~w(phone_numbers addresses social_media_accounts emails)a

  def up do
    for table <- @tables do
      alter table(table) do
        add(:position, :integer)
      end
    end

    # Run the backfill after every column exists so a failure cannot leave one
    # table with a column and no seed.
    for table <- @tables do
      execute("""
      UPDATE #{table} AS t
      SET position = ranked.rn
      FROM (
        SELECT id, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY id) AS rn
        FROM #{table}
      ) AS ranked
      WHERE t.id = ranked.id
      """)
    end
  end

  def down do
    for table <- @tables do
      alter table(table) do
        remove(:position)
      end
    end
  end
end
