defmodule Vutuv.Repo.Migrations.CreatePosts do
  use Ecto.Migration

  def change do
    # On the integer -> UUID upgrade path the legacy tables (users, groups,
    # tags) are still bigint when this runs: the conversion to UUID is the
    # later convert_ids_to_uuid_v7 migration, which converts these new tables
    # along with the rest. A from-scratch build has no legacy ids — the repo's
    # binary_id default already made every id a UUID. Either way these primary
    # keys and foreign keys must match users.id AS IT IS NOW, or the FK
    # creation fails on a uuid/bigint type mismatch.
    legacy? = legacy_int_ids?()
    fk = if legacy?, do: :bigint, else: :binary_id
    table_opts = if legacy?, do: [primary_key: [name: :id, type: :bigserial]], else: []

    create table(:posts, table_opts) do
      add(:user_id, references(:users, type: fk, on_delete: :delete_all), null: false)
      add(:body, :text, null: false, default: "")
      # The permalink is /:slug/:year/:month/:day/:seq — published_on is the
      # UTC date at insert time, seq a per-user-per-day counter.
      add(:published_on, :date, null: false)
      add(:seq, :integer, null: false)

      timestamps()
    end

    create(unique_index(:posts, [:user_id, :published_on, :seq]))
    # The feed and profile lists read newest-first per author set.
    create(index(:posts, [:user_id, :inserted_at]))

    # Deny-model audiences: a post is visible to everyone except readers
    # matching any denial row. Exactly one of group_id / denied_user_id /
    # wildcard is set per row (enforced below).
    create table(:post_denials, table_opts) do
      add(:post_id, references(:posts, type: fk, on_delete: :delete_all), null: false)
      # Restrict (not delete_all): silently dropping a denial when its group is
      # deleted would widen the audience of old posts. The group-deletion path
      # surfaces this as a friendly error instead.
      add(:group_id, references(:groups, type: fk, on_delete: :restrict))
      # delete_all: a denial against a deleted account is moot.
      add(:denied_user_id, references(:users, type: fk, on_delete: :delete_all))
      add(:wildcard, :string)

      timestamps()
    end

    create(
      constraint(:post_denials, :exactly_one_target,
        check: """
        (CASE WHEN group_id IS NOT NULL THEN 1 ELSE 0 END +
         CASE WHEN denied_user_id IS NOT NULL THEN 1 ELSE 0 END +
         CASE WHEN wildcard IS NOT NULL THEN 1 ELSE 0 END) = 1
        """
      )
    )

    create(unique_index(:post_denials, [:post_id, :group_id]))
    create(unique_index(:post_denials, [:post_id, :denied_user_id]))
    create(unique_index(:post_denials, [:post_id, :wildcard]))
    create(index(:post_denials, [:group_id]))
    create(index(:post_denials, [:denied_user_id]))

    create table(:post_images, table_opts) do
      # Nullable: images are uploaded eagerly while composing (the inline-image
      # markdown needs a URL before the post exists) and attached on submit;
      # unattached rows older than a day are swept.
      add(:post_id, references(:posts, type: fk, on_delete: :delete_all))
      add(:user_id, references(:users, type: fk, on_delete: :delete_all), null: false)
      # Random URL token; also the on-disk filename stem. Lookups and the
      # serving route go through it, never through the row id.
      add(:token, :string, null: false)
      add(:alt, :string, null: false, default: "")
      add(:position, :integer, null: false, default: 0)
      # Original dimensions after EXIF autorotation — clients reserve layout
      # space from these (and they survive into the API serialization).
      add(:width, :integer, null: false)
      add(:height, :integer, null: false)
      add(:content_type, :string, null: false)
      add(:size_bytes, :integer, null: false)

      timestamps()
    end

    create(unique_index(:post_images, [:token]))
    create(index(:post_images, [:post_id]))
    # The pending sweep scans unattached rows by age.
    create(index(:post_images, [:inserted_at], where: "post_id IS NULL"))

    create table(:post_tags, table_opts) do
      add(:post_id, references(:posts, type: fk, on_delete: :delete_all), null: false)
      add(:tag_id, references(:tags, type: fk, on_delete: :delete_all), null: false)

      timestamps()
    end

    create(unique_index(:post_tags, [:post_id, :tag_id]))
    create(index(:post_tags, [:tag_id]))
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
