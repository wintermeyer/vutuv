defmodule Vutuv.Repo.Migrations.CreateFediversePostReposts do
  use Ecto.Migration

  @moduledoc """
  A member sharing a post from another network onward (issue #1166).

  Its own table rather than a nullable column on `post_reposts`, which is where
  a vutuv post's reposts live. That table's `post_id` is the spine of six
  queries — the feed source, the reposter roster, the audience lock, the profile
  filter — and making it nullable would put "or the other kind" into every one
  of them for a case they can never serve anyway: a remote repost has no local
  post, no author here, no audience lock to hold open. Two tables, two feed
  sources, one card.

  **`checked_at` on the cached post is the other half of this issue.** A
  reposted copy has to outlive the six-month ceiling — the repost is a standing
  claim that this is worth showing — but only while the original is still
  published. So the retention sweep skips a post somebody here reposted, and a
  slow re-fetch verifies it instead: still there pushes the ceiling out, a 404
  or 410 deletes the copy and the reposts with it. A repost never keeps alive
  what its author has already deleted upstream.
  """

  def change do
    create table(:fediverse_post_reposts) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:remote_post_id, references(:fediverse_posts, on_delete: :delete_all), null: false)

      timestamps(updated_at: false)
    end

    # The pair is the identity: reposting twice is the same repost. It also
    # serves the per-member lookup a feed page batches.
    create(unique_index(:fediverse_post_reposts, [:user_id, :remote_post_id]))
    # The cascade's own index, and the retention sweep's "is this reposted"
    # question.
    create(index(:fediverse_post_reposts, [:remote_post_id]))

    alter table(:fediverse_posts) do
      # When the origin last confirmed this post is still published. Null means
      # never asked, which is every row until it is first reposted — the check
      # exists for reposted copies alone, since nothing else here outlives its
      # ceiling.
      add(:checked_at, :utc_datetime)
    end
  end
end
