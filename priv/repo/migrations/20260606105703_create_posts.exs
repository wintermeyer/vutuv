defmodule Vutuv.Repo.Migrations.CreatePosts do
  use Ecto.Migration

  def change do
    create table(:posts) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
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
    create table(:post_denials) do
      add(:post_id, references(:posts, on_delete: :delete_all), null: false)
      # Restrict (not delete_all): silently dropping a denial when its group is
      # deleted would widen the audience of old posts. The group-deletion path
      # surfaces this as a friendly error instead.
      add(:group_id, references(:groups, on_delete: :restrict))
      # delete_all: a denial against a deleted account is moot.
      add(:denied_user_id, references(:users, on_delete: :delete_all))
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

    create table(:post_images) do
      # Nullable: images are uploaded eagerly while composing (the inline-image
      # markdown needs a URL before the post exists) and attached on submit;
      # unattached rows older than a day are swept.
      add(:post_id, references(:posts, on_delete: :delete_all))
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
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

    create table(:post_tags) do
      add(:post_id, references(:posts, on_delete: :delete_all), null: false)
      add(:tag_id, references(:tags, on_delete: :delete_all), null: false)

      timestamps()
    end

    create(unique_index(:post_tags, [:post_id, :tag_id]))
    create(index(:post_tags, [:tag_id]))
  end
end
