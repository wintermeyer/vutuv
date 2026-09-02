defmodule Vutuv.Repo.Migrations.AddScreenshotAttemptedAtToUrls do
  use Ecto.Migration

  # The clock `Vutuv.PageScreenshot.due/1` orders its batch by. Every attempt
  # stamps it, the ones that captured nothing included, so a page that can
  # never be shot leaves the front of the retry batch instead of holding it.
  #
  # No index: measured on this table's shape (1,937 rows, 43 heap pages) the
  # due query is a 0.086 ms sequential scan, and an index on the one column
  # every capture writes would cost each stamp its HOT update. Worth revisiting
  # at two orders of magnitude more links — and then as
  # `["screenshot_attempted_at ASC NULLS FIRST"]`, since a default btree cannot
  # serve that ordering and the planner falls back to a full sort anyway.
  #
  # A plain nullable column: N-1 compatible, the previous release neither reads
  # nor writes it.
  def change do
    alter table(:urls) do
      add(:screenshot_attempted_at, :naive_datetime)
    end
  end
end
