defmodule Vutuv.Repo.Migrations.CreateMediaJobs do
  use Ecto.Migration

  # The media-job log (issue #2103): one row per step the media pipelines run,
  # so an admin can see at /admin/media what is running, what finished, how long
  # it took and how it ended — today only the server log knows, and each
  # pipeline keeps its own status column on its own row.
  #
  # Purely additive, so it is N-1 compatible: the currently deployed release
  # neither reads nor writes this table.
  def change do
    create table(:media_jobs) do
      # image_scan / video_conversion / screenshot.
      add(:kind, :string, null: false)

      # running / done / failed.
      add(:status, :string, null: false)

      # What the step worked on, plus that row's id. Deliberately NOT a foreign
      # key: the subject lives in a different table per kind, and a log row has
      # to outlive the picture it is about.
      add(:subject_type, :string)
      add(:subject_id, :binary_id)

      # Both nullable and both nilify: a screenshot of a remote post has no
      # member here, a clip has no post until it is published, and deleting
      # either must not take the log row with it. These two are the only
      # foreign keys — the page links back through the post rather than growing
      # a reference to every media table.
      add(:user_id, references(:users, on_delete: :nilify_all))
      add(:post_id, references(:posts, on_delete: :nilify_all))

      # How it ended, in words. Capped at the column width by Vutuv.MediaJobs
      # before it is written, so an unbounded `inspect/1` of a failure reason
      # cannot raise 22001 on the failure path.
      add(:detail, :string)

      # How long it took is the difference of these two; there is deliberately
      # no duration column to keep in step with them.
      add(:started_at, :utc_datetime_usec, null: false)
      add(:finished_at, :utc_datetime_usec)
    end

    # The page's default order (newest first) and the retention sweep.
    create(index(:media_jobs, ["started_at DESC"]))

    # Not for the queries: both foreign keys are `nilify_all`, which Postgres
    # enforces with an UPDATE ... WHERE <fk> = $1 per deleted row. Without these
    # every account deletion and every post deletion scans the whole table — and
    # this installation deletes posts on a schedule.
    #
    # `kind` and `status` get no index on purpose: the search is a leading-%
    # ILIKE that a btree cannot serve, both columns hold three values, and
    # `status` is rewritten on every close, where a second index would cost a
    # non-HOT update per job.
    create(index(:media_jobs, [:user_id]))
    create(index(:media_jobs, [:post_id]))
  end
end
