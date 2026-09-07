defmodule Vutuv.Repo.Migrations.AddOrganizationImagesToImages do
  use Ecto.Migration

  # The third of the four kinds #2015 moves into the shared `images` table
  # (issue #2053), and the one whose *owner* is not a member.
  #
  # Expand half only: this takes nothing away and nothing reads the new
  # columns, so the release serving traffic while it runs is unaffected. The
  # release it ships with writes a row here beside every `organization_images`
  # row; the deploy after that moves the readers and the takedown onto it, and
  # only the one after *that* retires the old table.
  #
  # **Only two columns are new.** The six every gallery row shares (`alt`,
  # `position`, `width`, `height`, `content_type`, `size_bytes`) arrived with
  # #2054 at exactly the types `organization_images` holds them at — varchar(255)
  # for `alt` and `content_type`, plain `integer` for the other four (a logo is
  # capped at 4 MB, so `size_bytes` needs no bigint) — and `token` and
  # `moderation` have been here since #2013.
  #
  # ## Who owns a page's picture
  #
  # `images.user_id` means "a member owns this" and is
  # `ON DELETE CASCADE`, which is right for an avatar, a post photo and a
  # job-posting picture: all three die with the member (`post_images.user_id`
  # and `job_posting_images.user_id` are NOT NULL and cascade too). An
  # organization image is the opposite: `organization_images.user_id` is
  # nullable and `ON DELETE SET NULL` **on purpose**, because a page's logo
  # belongs to the page and has to survive the member who uploaded it closing
  # their account (`Vutuv.Accounts.delete_user/1` deliberately does not collect
  # these files, unlike the job-posting ones).
  #
  # So copying the uploader into `images.user_id` would arm a cascade that
  # deletes a page's logo row the day its uploader leaves — silently, and only
  # the release that reads this row would notice, by rendering the page with no
  # logo. The owner column for this kind is therefore `organization_id`; the
  # uploader gets a column of its own with the referential action its source
  # has. A copied column carries its sibling's type; this one also carries its
  # sibling's `ON DELETE`.
  def up do
    alter table(:images) do
      # The owning page. Nullable because a description picture is uploaded
      # *before* the page saves it (the `organization_id IS NULL` lifecycle
      # `organization_images` has carried since #929), and because no other
      # kind has a page.
      add(:organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all))

      # Who uploaded it — not who owns it. `nilify_all`, exactly as
      # `organization_images.user_id` is: the page keeps the picture, the
      # account keeps nothing. Read at release two by the proxy's
      # "an unattached upload is visible to its uploader" branch
      # (`Vutuv.Organizations.image_visible_to?/2`) and by the re-enqueue of a
      # stranded scan, which needs somebody to send the rejection notice to.
      add(:uploader_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
    end

    # The cascade's own lookup, for the same reason `images.job_posting_id` and
    # `images.post_id` have one: deleting a page would otherwise scan a table
    # that ends up holding every picture in the system. **Partial**, following
    # #2054 — every other kind's row is NULL here, and #2054 measured that
    # Postgres proves `IS NOT NULL` from the referential trigger's strict
    # `= $1` and takes a Bitmap Index Scan on such an index. Sizes at
    # vutuv.de's distribution are below; the plan claim is #2054's, not
    # re-measured here, because four rows in a 1,917-row table are a sequential
    # scan whatever index exists.
    create(index(:images, [:organization_id], where: "organization_id IS NOT NULL"))

    # The same, for the SET NULL trigger an account deletion fires. Partial for
    # the same reason: only this kind ever fills the column.
    create(index(:images, [:uploader_user_id], where: "uploader_user_id IS NOT NULL"))

    # `images_profile_kind_has_owner` says which kinds must name a **member**,
    # and this kind deliberately does not join that list. This is the other
    # half of the same statement, and it is a constraint rather than a comment
    # because `Vutuv.Images.mirror/2` writes through `insert_all`: no changeset
    # stands between a future author who "fixes" the empty `user_id` and the
    # cascade above.
    create(
      constraint(:images, :images_organization_kind_has_no_member_owner,
        check: "kind <> 'organization_image' OR user_id IS NULL"
      )
    )

    # **Not concurrent, measured rather than assumed.** `images` holds 1,913 rows
    # on the production copy (1,682 avatars, 70 covers, 161 post photos since
    # #2052), and vutuv.de has 4 organization images to add. Adding a nullable
    # column with no default is metadata-only since Postgres 11; the two index
    # builds and the constraint validation each scan that table once. Measured
    # on my own copy of that database with all 1,913 rows in place, the whole
    # migration took **9.9 ms**: 4.0 ms and 1.2 ms for the two columns, 2.7 ms
    # and 1.1 ms for the indexes, 0.9 ms for the constraint.
    # `CREATE INDEX CONCURRENTLY` would cost two scans,
    # `@disable_ddl_transaction` and a migration that cannot roll back, to save
    # a lock nobody would notice. Revisit when `images` reaches the millions:
    # the shapes to reach for then are `CREATE INDEX CONCURRENTLY` and
    # `ADD CONSTRAINT … NOT VALID` followed by `VALIDATE CONSTRAINT`, which
    # takes only SHARE UPDATE EXCLUSIVE and lets writes carry on.
    #
    # Both indexes measured 16 kB partial against 32 kB full at that
    # distribution — the partial form only pays off while this kind is a
    # minority of the table, which it is and stays: 4 rows against 1,913.
  end

  def down do
    drop(constraint(:images, :images_organization_kind_has_no_member_owner))
    drop(index(:images, [:uploader_user_id], where: "uploader_user_id IS NOT NULL"))
    drop(index(:images, [:organization_id], where: "organization_id IS NOT NULL"))

    alter table(:images) do
      remove(:uploader_user_id)
      remove(:organization_id)
    end
  end
end
