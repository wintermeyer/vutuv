defmodule Vutuv.Repo.Migrations.CreateImagesTable do
  use Ecto.Migration

  # One row per stored picture (issue #2013). The reasoning is in
  # `docs/architecture/images.md`; what matters here is that this is the expand
  # half of an expand/contract and takes nothing away — a new table, two
  # nullable columns on `users`, N-1 safe for the blue/green window. #2014
  # backfills the pictures uploaded before this and drops the member row's four
  # columns per kind a deploy later.
  #
  # Column types are the ones the values are copied from: `users.avatar`,
  # `users.avatar_fingerprint`, `users.avatar_crop` and
  # `users.avatar_moderation` are all varchar(255), `post_images.token` is
  # varchar(255) with a unique index, and every `frozen_at` here is a
  # naive_datetime.
  def change do
    create table(:images) do
      # "avatar" and "cover" today — the same vocabulary
      # `Vutuv.Moderation.ImageScans` uses for its scan kinds. The remaining
      # kinds (post_image, organization_image, job_posting_image,
      # review_cover) move in one at a time in #2015.
      add(:kind, :string, null: false)

      # The owner. Deliberately **nullable** although both kinds here always
      # have one: the kinds #2015 brings are owned by a post, an organization
      # or a job posting, not by a member, so they will add a column of their
      # own beside this one. Widening a NOT NULL column afterwards is the
      # expensive migration this project has been bitten by repeatedly
      # (#1334/#1336); a check constraint scoped to the kinds that do have a
      # member owner costs nothing and is cheap to extend.
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all))

      # An unguessable handle, so a report form (#2012) can name a picture
      # without exposing a row id. This is also the column `post_images.token`
      # moves into in #2015 — that token is the lookup key of the post-image
      # proxy and its on-disk directory name, so it has to be unique across
      # the whole table from the start.
      add(:token, :string, null: false)

      # The three columns a profile picture keeps today, copied verbatim: the
      # upload's own file name, the content fingerprint baked into the served
      # file name, and the member's crop rectangle.
      add(:file, :string)
      add(:fingerprint, :string)
      add(:crop, :string)

      # The AI image gate's verdict (`Vutuv.Moderation.ImageScans`):
      # nil = grandfathered, "pending" = in quarantine, "approved" = released.
      add(:moderation, :string)

      # When a moderation case took this picture offline. Nothing writes it
      # yet; #2012 does, and a freeze moves files rather than deleting them.
      add(:frozen_at, :naive_datetime)

      timestamps()
    end

    create(unique_index(:images, [:token]))

    # The cascade's own lookup. The partial index below cannot serve it: the
    # planner cannot prove `kind IN (…)` holds for a bare `WHERE user_id = $1`,
    # so deleting an account would scan the table — and after #2015 this table
    # holds every picture in the system.
    create(index(:images, [:user_id]))

    # A member has at most one avatar and one cover. Partial, so the kinds
    # #2015 brings (a post has many photos) are not caught by it. It is also
    # the conflict target `Vutuv.Images.put_profile_image/3` upserts on.
    create(
      unique_index(:images, [:user_id, :kind],
        where: "kind IN ('avatar', 'cover')",
        name: :images_member_profile_kind_index
      )
    )

    create(
      constraint(:images, :images_profile_kind_has_owner,
        check: "kind NOT IN ('avatar', 'cover') OR user_id IS NOT NULL"
      )
    )

    alter table(:users) do
      # The pointer at the row above. Nullable and unread by the release this
      # migration runs against; the four per-kind columns stay the source of
      # truth until #2014 has backfilled every member and dropped them.
      add(:avatar_image_id, references(:images, type: :binary_id, on_delete: :nilify_all))
      add(:cover_image_id, references(:images, type: :binary_id, on_delete: :nilify_all))
    end

    # `nilify_all` looks for referencing rows on every image delete (a rejected
    # or canceled scan today, #2014's contract pass later), so both sides of
    # the pointer are indexed — the shape `users_pinned_post_id_index` and the
    # two profile-section pointers already have.
    create(index(:users, [:avatar_image_id]))
    create(index(:users, [:cover_image_id]))
  end
end
