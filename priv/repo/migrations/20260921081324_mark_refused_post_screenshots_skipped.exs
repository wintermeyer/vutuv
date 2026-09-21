defmodule Vutuv.Repo.Migrations.MarkRefusedPostScreenshotsSkipped do
  @moduledoc """
  Moves the post screenshot jobs that were refused for good out of `failed` and
  into `skipped`, so the admin queue holds only work. A refusal is recognised by
  the reason `Vutuv.Posts.Screenshots` wrote into `last_error` (`inspect/1` of
  the reason atom or tuple), the same set its `permanent_failure?/1` names, plus
  the AI scan's rejection. A 408 or 429 counted as permanent until now and stays
  `failed`, which puts it in the queue with a Retry: it only ever meant "later".

  Only the status moves: a `:redirect` row stays refused even where the new
  same-site rule would now follow it, because re-queueing here would hand the
  jobs to the release still serving during the deploy, which refuses them again.

  N-1 safe: the old release reads `skipped` as an unknown unfinished status and
  lists it in its queue, as it listed these rows before.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE post_screenshots
    SET status = 'skipped'
    WHERE status = 'failed'
      AND (last_error IN (':internal_target', ':blocklisted', ':obstructed', ':redirect',
                          'moderation_rejected')
           OR (last_error LIKE '{:bad_status, %'
               AND last_error NOT IN ('{:bad_status, 408}', '{:bad_status, 429}')))
    """)
  end

  def down do
    execute("UPDATE post_screenshots SET status = 'failed' WHERE status = 'skipped'")
  end
end
