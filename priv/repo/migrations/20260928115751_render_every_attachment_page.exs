defmodule Vutuv.Repo.Migrations.RenderEveryAttachmentPage do
  @moduledoc """
  Hands every PDF that was rendered while only its first pages were back to
  the page pipeline, so it gets (and the AI scan judges) the rest.

  The claim is stamped ten minutes **into the future** rather than left for the
  next poll. This migration runs while the previous release is still serving,
  and that release would find the file due, see its three pages already there
  and settle it `ready` again within seconds. Neither release touches a claim
  younger than the staleness window, so the old slot never sees these files
  and the new one picks them up ten minutes after the migration.
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE attachments AS a
    SET stage = 'rendering',
        worked_at = date_trunc('second', (now() AT TIME ZONE 'utc') + interval '10 minutes'),
        render_attempts = 0
    WHERE a.content_type = 'application/pdf'
      AND a.stage = 'ready'
      AND a.refused_at IS NULL
      AND a.frozen_at IS NULL
      AND a.page_count > (
        SELECT count(*) FROM images i
        WHERE i.kind = 'attachment_page' AND i.attachment_id = a.id
      )
    """)
  end

  def down, do: :ok
end
