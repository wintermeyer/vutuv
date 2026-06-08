defmodule Vutuv.Repo.Migrations.CreatePostEngagement do
  use Ecto.Migration

  def change do
    # See create_posts: on the integer -> UUID upgrade path users.id/posts.id
    # are still bigint here (convert_ids_to_uuid_v7 runs later and converts
    # these too); a from-scratch build already has UUID ids. Match the live id
    # type or the FK creation fails on a uuid/bigint mismatch.
    legacy? = legacy_int_ids?()
    fk = if legacy?, do: :bigint, else: :binary_id
    table_opts = if legacy?, do: [primary_key: [name: :id, type: :bigserial]], else: []

    # Likes, bookmarks and reposts share one shape: a (post, user) pair,
    # unique per pair (toggles are idempotent), cascading away with either
    # side. Counters are counted live from these rows — no counter caches to
    # drift. The [user_id, inserted_at] indexes back the "my likes" / "my
    # bookmarks" pages and the reposts-by-followees feed leg.
    for table_name <- [:post_likes, :post_bookmarks, :post_reposts] do
      create table(table_name, table_opts) do
        add(:post_id, references(:posts, type: fk, on_delete: :delete_all), null: false)
        add(:user_id, references(:users, type: fk, on_delete: :delete_all), null: false)

        timestamps()
      end

      create(unique_index(table_name, [:post_id, :user_id]))
      create(index(table_name, [:user_id, :inserted_at]))
    end
  end

  # True while the legacy integer ids are still in place (the upgrade path);
  # false on a from-scratch build where the repo's binary_id default already
  # made every id a UUID. Probing users.id is representative: every legacy
  # table is bigint until convert_ids_to_uuid_v7 converts them all at once.
  defp legacy_int_ids? do
    %{rows: [[type]]} =
      repo().query!(
        "SELECT data_type FROM information_schema.columns " <>
          "WHERE table_name = 'users' AND column_name = 'id'"
      )

    type == "bigint"
  end
end
