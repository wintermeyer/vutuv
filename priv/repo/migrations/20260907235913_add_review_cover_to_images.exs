defmodule Vutuv.Repo.Migrations.AddReviewCoverToImages do
  use Ecto.Migration

  # The last of the four kinds #2015 brings into the shared `images` table
  # (issue #2055): the cover of a book review. Expand half — one nullable
  # column, one partial index, one check constraint, and not a byte of the
  # picture moves. N-1 safe: the release one step back neither reads nor
  # writes any of it.
  #
  # **This kind is not the gallery shape.** A post photo, an organization
  # image and a job-posting picture each carry a `token` of their own, so the
  # mirror joins them on it. A review's cover is `cover` / `cover_status` /
  # `cover_moderation` columns on `post_reviews` with no token and no table of
  # its own, so this column *is* the join key as well as the parent — one
  # cover per review, hence a unique index rather than the plain one the other
  # three parents got.
  #
  # No column type question: `post_reviews.cover` and `cover_moderation` are
  # varchar(255) and copy into `images.file` and `images.moderation`, which are
  # varchar(255) too. `cover_status` deliberately stays behind — see
  # `docs/architecture/images.md`; it is the *fetch* lifecycle, and there is no
  # picture at all while it says none/pending/failed.
  def change do
    alter table(:images) do
      # Cascades like `post_reviews.post_id` does from `posts`: deleting the
      # post takes the review and its cover row with it in one statement.
      add(:post_review_id, references(:post_reviews, type: :binary_id, on_delete: :delete_all))
    end

    # Partial, like the other three parents': every other kind's row is NULL
    # here. Unique, unlike theirs: a review has exactly one cover, so this is
    # the join key the mirror upserts on. It also serves the cascade's own
    # `WHERE post_review_id = $1`, which Postgres can prove `IS NOT NULL` from.
    create(
      unique_index(:images, [:post_review_id],
        where: "post_review_id IS NOT NULL",
        name: :images_post_review_id_index
      )
    )

    # The shape a comment cannot hold: `Vutuv.Images.sync_review_cover/1`
    # writes through `insert_all`, so no changeset stands between a future
    # author who "fills in" `user_id` and the `ON DELETE CASCADE` that would
    # then delete a publisher's cover the day the reviewer closes their
    # account. Nobody uploaded this picture — the review owns it, and the post
    # under it need not have a member author at all (an organization's review
    # post has `posts.user_id` NULL).
    create(
      constraint(:images, :images_review_kind_owned_by_review,
        check:
          "kind <> 'review_cover' OR (post_review_id IS NOT NULL AND user_id IS NULL)"
      )
    )
  end
end
