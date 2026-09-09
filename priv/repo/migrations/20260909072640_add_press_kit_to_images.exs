defmodule Vutuv.Repo.Migrations.AddPressKitToImages do
  use Ecto.Migration

  # The press photo and the vector logo a journalist may download (issue #2083,
  # the first piece of #2082). Unlike the four kinds #2015 moved in here, this
  # one is **born** on `images` and has no table of its own: there is no mirror,
  # no backfill and no contract release, so nothing about it is transitional.
  #
  # Expand only, and N-1 safe twice over: three nullable columns with no default
  # (metadata-only since Postgres 11) and two check constraints that restrict
  # exactly one `kind` string no deployed release writes. The release one step
  # back neither reads nor writes any of it.
  #
  # ## Only three columns are new
  #
  # A press picture is mostly the gallery shape #2054 settled: `token`,
  # `moderation`, `frozen_at`, `alt`, `position`, `width`, `height`,
  # `content_type` and `size_bytes` are already here, `caption` arrived with the
  # post photo (#2052) — `:text`, which is what a Markdown caption naming the
  # photographer's handle wants — and `user_id`, `organization_id` and
  # `uploader_user_id` are the ownership pair #2053 built.
  #
  #   * `credit` — the line shown beside the picture ("Foto: Ada King"). A
  #     user-writable varchar(255), the type `alt` and `content_type` already
  #     have; `Vutuv.Images.Image.press_kit_changeset/2` validates the length,
  #     because Ecto does not enforce a column limit and an over-long value
  #     raises Postgres 22001 on a plain form submit.
  #   * `rights_confirmed_at` — when the uploader confirmed they hold the rights
  #     and release the file for editorial use with the credit shown. It is the
  #     legal basis for handing the original out at all, so the constraint below
  #     makes a press row without one impossible rather than merely unusual.
  #     `:naive_datetime`, like every other timestamp on this table
  #     (`frozen_at`, `taken_at`, `inserted_at`), written from the same
  #     `NaiveDateTime.utc_now(:second)` the table already uses. The two consent
  #     columns elsewhere in this project (`qualifications.document_consented_at`,
  #     `job_references.public_consented_at`) are `:utc_datetime`; both map to
  #     the same Postgres `timestamp`, and matching the table this column lives
  #     on beats matching a column on another one.
  #   * `logo` — which shelf the row is on. A photo and a logo are one kind with
  #     one set of caps-per-shelf rather than two kinds, because everything else
  #     about them (owner, token, moderation, takedown, proxy) is identical and
  #     a second kind would have to be registered twice in every list #2084 and
  #     #2089 extend. **Nullable and no default**, following #2052: every other
  #     kind's row has no opinion about a press shelf, and NULL is how it says
  #     so. The constraint below makes it NOT NULL for this kind alone, so a row
  #     can never fall off both shelves and become invisible to both queries.
  #
  # ## No new index, measured rather than assumed
  #
  # The two lookups this kind adds are "every press row of this member" and
  # "every press row of this page", and both already have an index:
  # `images_user_id_index` (full, from #2013) and
  # `images_organization_id_index` (partial, from #2053).
  #
  # Note what the member one actually costs, because the obvious reasoning is
  # wrong: `images.user_id` is not "this member's press kit", it is **every**
  # picture they own — their avatar, their cover and, since #2052, every photo
  # on every post they ever wrote. Measured on the dev copy on 2026-09-09, the
  # busiest member has 60 post photos and the average is 5.8, so the scan is
  # tens of index entries filtered down to at most 15, and it grows with how
  # much the member posts rather than with the press-kit cap. It is still not
  # worth an index at these numbers — sixty heap fetches are nothing — but the
  # reason is the absolute row count, not the cap. If it ever is,
  # `index(:images, [:user_id, :logo, :position], where: "kind = 'press_kit'")`
  # serves the filter and the sort together.
  #
  # Sizes, measured on the dev copy of production on 2026-09-09: `images` holds
  # 25 rows and 152 kB there because `mix vutuv.images.backfill` has not run on
  # it; the pictures it will hold once it has are 1,691 avatars, 77 covers, 168
  # post photos and 5 organization images (vutuv.de has no job postings) —
  # ~1,941 rows, the same order as the 1,913 #2053 measured.
  #
  # **Timed rather than assumed**, on a copy of that table padded to 2,000 rows:
  # **1.4 ms** for the whole migration — 0.24 ms for the three columns
  # (metadata-only, as expected), 0.74 ms and 0.38 ms for the two constraint
  # validations, which are the only full scans here. `ADD CONSTRAINT … NOT VALID`
  # followed by `VALIDATE CONSTRAINT` would save a sub-millisecond ACCESS
  # EXCLUSIVE lock and cost a two-statement migration; revisit when `images`
  # reaches the millions, and that is the shape to reach for then.
  def change do
    alter table(:images) do
      add(:credit, :string)
      add(:rights_confirmed_at, :naive_datetime)
      add(:logo, :boolean)
    end

    # **Exactly one owner, never both.** A member's press kit is theirs and
    # cascades with the account; a page's belongs to the page and outlives the
    # colleague who uploaded it, so `images.user_id` — which is
    # `ON DELETE CASCADE` — must stay empty for a page's row and the uploader
    # rides in `uploader_user_id` (`ON DELETE SET NULL`), exactly as #2053
    # settled for an organization image. Naming both would arm that cascade on
    # a picture the page owns.
    #
    # `(a IS NULL) <> (b IS NULL)` is the XOR: true when exactly one side is
    # filled. It is a constraint rather than a comment because `Vutuv.PressKit`
    # is not the only door that could ever write this table — `mirror/2` and
    # `sync_review_cover/1` already write through `insert_all`, where no
    # changeset stands between a future author and the cascade.
    create(
      constraint(:images, :images_press_kit_has_one_owner,
        check: "kind <> 'press_kit' OR ((user_id IS NULL) <> (organization_id IS NULL))"
      )
    )

    # The two facts a press picture cannot be without: which shelf it is on, and
    # that somebody released it. A NULL `logo` would put the row on neither
    # shelf — invisible to the photo query and to the logo query alike, with
    # nothing raising — and a missing `rights_confirmed_at` would leave a file
    # offered for download that nobody ever said may be downloaded.
    create(
      constraint(:images, :images_press_kit_declared,
        check:
          "kind <> 'press_kit' OR (logo IS NOT NULL AND rights_confirmed_at IS NOT NULL)"
      )
    )
  end
end
