defmodule Vutuv.Repo.Migrations.AddJobPostingImagesToImages do
  use Ecto.Migration

  # The first of the four kinds #2015 moves into the shared `images` table
  # (issue #2054), and the smallest — so the shape settled here is the one the
  # post photo, the organization image and the review cover repeat.
  #
  # Expand half only: this takes nothing away and nothing reads the new
  # columns, so the release serving traffic while it runs is unaffected. The
  # release it ships with writes a row here beside every `job_posting_images`
  # row; the deploy after that retires the old table together with the double
  # write.
  #
  # **Column types are the ones the values are copied from**, read off
  # `job_posting_images` rather than defaulted: `alt` and `content_type` are
  # varchar(255) there, `position`, `width`, `height` and `size_bytes` are
  # plain `integer` (a posting image is capped at 6 MB, so `size_bytes` needs
  # no bigint), and `token` and `moderation` already exist here with exactly
  # those types.
  #
  # There is deliberately **no reverse pointer** the way `users.avatar_image_id`
  # is one. A member row had no stable handle of its own, so #2013 had to add
  # one; a gallery row already carries a `token` that is unique in both tables
  # and never re-minted, and `images.token` has been unique across the whole
  # table since #2013 precisely so these kinds could move in on it. The token
  # is therefore the join key, which also means this kind has no
  # `missing_pointer` class to reconcile.
  def up do
    alter table(:images) do
      # The parent posting. Nullable because a posting image is uploaded
      # *before* the posting is saved (`job_posting_id` stays nil while the
      # composer's gallery is pending, and `Jobs.sweep_pending_images/1`
      # collects what is never attached), and because no other kind has one.
      add(:job_posting_id, references(:job_postings, type: :binary_id, on_delete: :delete_all))

      # The six columns a gallery row holds beside the ones this table already
      # has. `post_images` and `organization_images` carry the same six under
      # the same names, so the next two kinds add none of them — only their own
      # parent column above.
      add(:alt, :string)
      add(:position, :integer)
      add(:width, :integer)
      add(:height, :integer)
      add(:content_type, :string)
      add(:size_bytes, :integer)
    end

    # The cascade's own lookup, for the same reason `images.user_id` is indexed:
    # deleting a posting would otherwise scan a table that ends up holding every
    # picture in the system. No query this release adds needs it — the mirror
    # upserts on `token`, `forget/2` filters on `token`, and the backfill joins
    # on `token`, all served by `images_token_index`.
    #
    # **Partial**, unlike `images.user_id`, because every other kind's row has a
    # NULL here and the waste multiplies by four as #2015's remaining kinds add
    # a parent column each. Postgres proves `IS NOT NULL` from the referential
    # trigger's strict `job_posting_id = $1` and uses it: measured on a copy of
    # the dev database with 4,163 image rows of which 1,216 carry a posting, the
    # trigger takes a Bitmap Index Scan on this index, and it is 16 kB against
    # 48 kB for the full one. The next kinds should copy this rather than
    # `images.user_id`, which predates the question.
    create(index(:images, [:job_posting_id], where: "job_posting_id IS NOT NULL"))

    # #2013 asked the kinds that arrive here to **extend** this constraint
    # rather than widen the nullable `user_id` column. A posting image always
    # has an uploader (`job_posting_images.user_id` is NOT NULL), so it joins
    # the list. N-1 safe: the release serving traffic writes only avatar and
    # cover rows, both of which already satisfy the wider check.
    drop(constraint(:images, :images_profile_kind_has_owner))

    create(
      constraint(:images, :images_profile_kind_has_owner,
        check: "kind NOT IN ('avatar', 'cover', 'job_posting_image') OR user_id IS NOT NULL"
      )
    )
  end

  def down do
    drop(constraint(:images, :images_profile_kind_has_owner))

    create(
      constraint(:images, :images_profile_kind_has_owner,
        check: "kind NOT IN ('avatar', 'cover') OR user_id IS NOT NULL"
      )
    )

    drop(index(:images, [:job_posting_id], where: "job_posting_id IS NOT NULL"))

    alter table(:images) do
      remove(:job_posting_id)
      remove(:alt)
      remove(:position)
      remove(:width)
      remove(:height)
      remove(:content_type)
      remove(:size_bytes)
    end
  end
end
