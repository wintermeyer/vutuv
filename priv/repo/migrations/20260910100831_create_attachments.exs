defmodule Vutuv.Repo.Migrations.CreateAttachments do
  use Ecto.Migration

  # Files on posts and messages (issue #2104): the row the composer's upload
  # writes, and the ledger the per-member budget is counted from.
  #
  # Two new tables and nothing else — purely additive, so the release still
  # serving traffic during the blue/green window neither reads nor writes
  # either of them (N-1).
  def change do
    create table(:attachments) do
      # The parent, one nullable column each: a file hangs under a post
      # (#2106) or under a private message (#2110), and under neither while
      # the composer still holds it. Every query over these has to carry an
      # `is_nil/1` branch of its own — a NULL in a `NOT IN` list makes the
      # whole predicate false, and an inner join to `posts` would silently
      # drop every message's file (the trap in CLAUDE.md).
      add(:post_id, references(:posts, type: :binary_id, on_delete: :delete_all))
      add(:message_id, references(:messages, type: :binary_id, on_delete: :delete_all))
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      # The lookup key and the on-disk directory name, never the row id.
      add(:token, :string, null: false)

      # What the member sent, kept for display and for the download's name.
      # The sniffed format decides `content_type`, never the browser's claim.
      add(:file_name, :string, null: false)
      add(:content_type, :string, null: false)
      add(:size_bytes, :bigint, null: false)

      # How many pages the PDF has (`pdfinfo`), nil for a text file. What
      # #2105 renders previews from.
      add(:page_count, :integer)

      # Where the pipeline is: stored -> ready, or failed. #2105 adds the
      # rendering steps between them; today an accepted file is `stored`, so
      # nothing writes this yet and the default is the whole answer.
      add(:stage, :string, null: false, default: "stored")

      timestamps()
    end

    create(unique_index(:attachments, [:token]))
    create(index(:attachments, [:post_id]))
    create(index(:attachments, [:message_id]))
    # The abandoned-composer sweep, like the pending-image and pending-clip
    # ones: a row with neither parent and old enough.
    create(
      index(:attachments, [:inserted_at],
        where: "post_id IS NULL AND message_id IS NULL",
        name: :attachments_pending_inserted_at_index
      )
    )

    # The budget ledger. Deliberately its own table rather than a sum over
    # `attachments`: the budget counts **accepted uploads**, so deleting a
    # file (or having the sweep take it) must not give the member their
    # megabytes back. Nothing here identifies the file, only that a member
    # was granted so many bytes at so much o'clock.
    create table(:attachment_uploads) do
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:size_bytes, :bigint, null: false)

      timestamps(updated_at: false)
    end

    # The only query there is: this member's accepted bytes since a cutoff.
    create(index(:attachment_uploads, [:user_id, :inserted_at]))
  end
end
