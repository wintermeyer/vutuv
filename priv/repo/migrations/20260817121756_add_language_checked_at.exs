defmodule Vutuv.Repo.Migrations.AddLanguageCheckedAt do
  use Ecto.Migration

  # The scheduler's clock for language detection (issue #1535), one column per
  # translation subject. It says "we looked", never "we found something": a
  # text the model could not place keeps `language` NULL (shown to everyone,
  # never auto-translated) and is stamped anyway, so it leaves the work list
  # instead of holding the front of every oldest-first batch — the
  # `refresh_counts` starvation lesson.
  #
  # The partial indexes cover exactly the work list, so each one shrinks as
  # the backfill drains it and is empty once the pile is gone.
  def change do
    for table <- [:posts, :fediverse_posts, :fediverse_notes] do
      alter table(table) do
        add(:language_checked_at, :utc_datetime)
      end

      create(
        index(table, [:id],
          name: "#{table}_language_detection_index",
          where: "language IS NULL AND language_checked_at IS NULL"
        )
      )
    end
  end
end
