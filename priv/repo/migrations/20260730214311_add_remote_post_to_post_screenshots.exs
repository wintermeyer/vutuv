defmodule Vutuv.Repo.Migrations.AddRemotePostToPostScreenshots do
  use Ecto.Migration

  # A cached fediverse post (a followed account's post, `fediverse_posts`) can
  # now own a link-screenshot job too, so `post_screenshots` gets a second,
  # mutually exclusive owner column. Additive + a NOT NULL drop, so the
  # currently deployed release keeps working (N-1 compatible): it only ever
  # writes `post_id` rows, which satisfy the new exactly-one-owner check.
  def change do
    alter table(:post_screenshots) do
      # The type stays; this is only ALTER COLUMN ... DROP NOT NULL.
      modify(:post_id, :binary_id, null: true, from: {:binary_id, null: false})
      add(:remote_post_id, references(:fediverse_posts, on_delete: :delete_all))
    end

    # One screenshot per cached post, like the one-per-post index beside it.
    create(unique_index(:post_screenshots, [:remote_post_id]))

    # Exactly one owner: a row is a member post's or a cached remote post's,
    # never both and never neither.
    create(
      constraint(:post_screenshots, :post_screenshots_exactly_one_owner,
        check: "(post_id IS NULL) <> (remote_post_id IS NULL)"
      )
    )
  end
end
