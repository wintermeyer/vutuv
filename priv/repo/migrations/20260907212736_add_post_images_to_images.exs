defmodule Vutuv.Repo.Migrations.AddPostImagesToImages do
  use Ecto.Migration

  # The second of the four kinds #2015 moves into the shared `images` table
  # (issue #2052), and the largest: a post photo carries a caption, a crop,
  # seven camera facts, a GPS flag and the author's three switches beside the
  # columns every gallery row has.
  #
  # Expand half only: this takes nothing away and nothing reads the new
  # columns, so the release serving traffic while it runs is unaffected. The
  # release it ships with writes a row here beside every `post_images` row; the
  # deploy after that moves the readers and the takedown onto it, and only the
  # one after *that* retires the old table.
  #
  # **Column types are the ones the values are copied from**, read off
  # `post_images` rather than defaulted. The one that matters is `caption`:
  # `:text` there, because a photographer's note runs to 1,000 characters
  # through the composer, and a varchar(255) copy would raise Postgres 22001
  # from `Vutuv.Images.mirror/2` — on the *write* path, where no changeset
  # validation stands between the member and the error. The camera facts are
  # display primitives in varchar(255) (`f/1.4`, `1/250 s`, `35 mm`), `iso` is
  # an integer, `taken_at` a naive_datetime and the four flags booleans.
  #
  # Six columns are **not** here because #2054 already added them for the
  # job-posting picture — `alt`, `position`, `width`, `height`, `content_type`,
  # `size_bytes` — and three more because a profile picture already had them:
  # `token` (the join key), `moderation`, and `crop`, which holds exactly what
  # `post_images.crop` holds (`"x,y,w,h"` fractions, ~27 bytes, varchar(255)).
  #
  # **Nullable, and no defaults**, the way #2054's six are, although four of
  # these are `NOT NULL DEFAULT false` on `post_images`: an avatar row has no
  # opinion about a camera panel, and NULL is how it says so. The mirror copies
  # the real `false` for a photo, so nothing reads a NULL as "off".
  #
  # There is deliberately **no reverse pointer** the way `users.avatar_image_id`
  # is one: a gallery row already carries a `token` that is unique in both
  # tables and never re-minted, and `images.token` has been unique across the
  # whole table since #2013 precisely so these kinds could move in on it.
  #
  # **Not concurrent, measured rather than assumed.** `images` holds 1,752 rows
  # on the production copy (1,682 avatars, 70 covers; vutuv.de has no job
  # postings) and this release's backfill adds one per post photo — 161 there,
  # so ~1,913 rows in 88 kB. Adding a nullable column with no default is
  # metadata-only since Postgres 11, and the index build and the constraint
  # revalidation each scan that table once: measured on a copy of it with the
  # 1,752 profile rows already in place, the whole migration took 14 ms (6 ms
  # for the thirteen columns, 3 ms for the index, 3 ms for the constraint).
  # `CREATE INDEX CONCURRENTLY` would cost two scans,
  # `@disable_ddl_transaction` and a migration that cannot roll back, to save a
  # lock nobody would notice. Revisit when `images` reaches the millions — the
  # sentence to re-read then is this one, and the two shapes it wants are
  # `CREATE INDEX CONCURRENTLY` and, for the constraint below (which is the
  # other full scan here, under ACCESS EXCLUSIVE), `ADD CONSTRAINT … NOT VALID`
  # followed by `VALIDATE CONSTRAINT`, which takes only SHARE UPDATE EXCLUSIVE
  # and lets writes carry on.
  def up do
    alter table(:images) do
      # The parent post. Nullable because a photo is uploaded *before* the post
      # exists (the composer needs a URL to reference it inline, and
      # `Vutuv.Posts.sweep_pending_images/1` collects what is never attached),
      # and because no other kind has a post.
      add(:post_id, references(:posts, type: :binary_id, on_delete: :delete_all))

      # Shown under the photo to everyone, and distinct from `alt`, which
      # describes the picture for people who cannot see it.
      add(:caption, :text)

      # The whitelisted camera facts (`Vutuv.Uploads.Exif`), parsed once at
      # upload and stored as the notation they are rendered in.
      add(:camera, :string)
      add(:lens, :string)
      add(:focal_length, :string)
      add(:aperture, :string)
      add(:shutter, :string)
      add(:iso, :integer)
      add(:taken_at, :naive_datetime)

      # Whether the upload carried location data — never the coordinates. It is
      # what lets the composer warn before the exact file is handed out, and it
      # is the reason it has to survive the deploy that drops `post_images`.
      add(:has_gps, :boolean)

      # The author's three per-photo switches.
      add(:show_camera_info, :boolean)
      add(:download_original, :boolean)
      add(:download_exact, :boolean)
    end

    # The cascade's own lookup, for the same reason `images.job_posting_id` has
    # one: deleting a post would otherwise scan a table that ends up holding
    # every picture in the system. No query this release adds needs it — the
    # mirror upserts on `token`, `forget/2` filters on `token` and the backfill
    # joins on `token`, all served by `images_token_index`.
    #
    # **Partial**, following #2054: every other kind's row is NULL here, and
    # Postgres proves `IS NOT NULL` from the referential trigger's strict
    # `post_id = $1` and uses it.
    create(index(:images, [:post_id], where: "post_id IS NOT NULL"))

    # #2013 asked the kinds that arrive here to **extend** this constraint
    # rather than widen the nullable `user_id` column. A post photo always has
    # an uploader (`post_images.user_id` is NOT NULL — for a page's post it is
    # the member who uploaded it, not the page), so it joins the list. N-1
    # safe: the release serving traffic writes only avatar, cover and
    # job-posting rows, all of which already satisfy the wider check.
    drop(constraint(:images, :images_profile_kind_has_owner))

    create(
      constraint(:images, :images_profile_kind_has_owner,
        check:
          "kind NOT IN ('avatar', 'cover', 'job_posting_image', 'post_image') " <>
            "OR user_id IS NOT NULL"
      )
    )
  end

  def down do
    drop(constraint(:images, :images_profile_kind_has_owner))

    create(
      constraint(:images, :images_profile_kind_has_owner,
        check: "kind NOT IN ('avatar', 'cover', 'job_posting_image') OR user_id IS NOT NULL"
      )
    )

    drop(index(:images, [:post_id], where: "post_id IS NOT NULL"))

    alter table(:images) do
      remove(:post_id)
      remove(:caption)
      remove(:camera)
      remove(:lens)
      remove(:focal_length)
      remove(:aperture)
      remove(:shutter)
      remove(:iso)
      remove(:taken_at)
      remove(:has_gps)
      remove(:show_camera_info)
      remove(:download_original)
      remove(:download_exact)
    end
  end
end
