defmodule Vutuv.Repo.Migrations.AddAttachmentPagesToImages do
  use Ecto.Migration

  # The preview pages a file shows under a post (issue #2105). Each rendered
  # page is a row on `images` of a new kind, `attachment_page`, so the AI scan,
  # the pixelated wait, the lite version and the lightbox reach it the way they
  # reach a photo — the shape #2083 established for the press kit, which is the
  # only other kind **born** on this table rather than mirrored into it.
  #
  # Expand only, and N-1 safe throughout: one nullable column and one integer
  # with a default on tables the previously deployed release still writes
  # (metadata-only since Postgres 11), two partial indexes, and a check
  # constraint restricted to a `kind` string no deployed release writes. The
  # release one step back neither reads nor writes any of it.
  def change do
    alter table(:images) do
      # The file this page was rendered from. A page has no life of its own:
      # delete the file and its previews go with it, which is why this cascades
      # rather than nilifying. It is deliberately **not** `post_id` as well —
      # an attachment carries the nullable post/message pair and is claimed by
      # one of them later (#2106, #2110), so a page that copied a parent at
      # render time would copy `nil` and then be wrong for ever.
      add(:attachment_id, references(:attachments, type: :binary_id, on_delete: :delete_all))
    end

    # The cascade's own lookup, and the "every page of this file" query. Partial
    # because almost no row in this table is an attachment page, and a bare
    # `WHERE attachment_id = $1` can use it: the predicate implies NOT NULL.
    create(
      index(:images, [:attachment_id],
        where: "attachment_id IS NOT NULL",
        name: :images_attachment_id_index
      )
    )

    # One row per page of a file, and the conflict target the render upserts on.
    # This is what makes a **resumed** render safe: a slot killed mid-loop is
    # picked up again, and a page that already has its row can never be written
    # twice — including by the two slots of a blue/green deploy overlap.
    create(
      unique_index(:images, [:attachment_id, :position],
        where: "kind = 'attachment_page'",
        name: :images_attachment_page_index
      )
    )

    # A page with no file is a picture nothing can find the bytes of and nothing
    # can delete: the scan reads its path through the file's token, and the
    # cascade above is the only thing that ever removes it.
    create(
      constraint(:images, :images_attachment_page_has_file,
        check: "kind <> 'attachment_page' OR attachment_id IS NOT NULL"
      )
    )

    alter table(:attachments) do
      # The claim heartbeat, exactly `post_videos.worked_at`: a claim is a
      # compare-and-set on this column, so the two slots of a deploy overlap can
      # never render the same file, and a row nobody has touched for the
      # staleness window is simply claimed again. That is the whole recovery
      # story for a render a deploy killed — the due list is a query, never
      # state in a process that dies with it.
      add(:worked_at, :utc_datetime)

      # How often the renderer was asked and failed. A strike is taken only when
      # the **external** side failed (poppler or Chromium ran and answered
      # non-zero); a host that has no renderer at all takes none, because that
      # is not a failure that retrying could fix.
      add(:render_attempts, :integer, null: false, default: 0)
    end

    # The due query, oldest first. Partial on the two unfinished stages, so the
    # index holds only work — every finished file leaves it.
    create(
      index(:attachments, [:inserted_at],
        where: "stage IN ('stored', 'rendering')",
        name: :attachments_render_due_index
      )
    )
  end
end
