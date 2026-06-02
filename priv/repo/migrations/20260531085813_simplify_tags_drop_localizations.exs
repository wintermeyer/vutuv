defmodule Vutuv.Repo.Migrations.SimplifyTagsDropLocalizations do
  use Ecto.Migration

  # Collapses the 1:1 tag_localizations into a plain name/description on tags and
  # drops the unused I18n machinery (tag_localizations, tag_synonyms, tag_urls,
  # tag_closures). In prod every tag has exactly one localization, so the backfill
  # below is lossless.
  #
  # One prod tag (id 7244, used by ~569 users) has both an empty localization name
  # and an empty slug. The repair/fallback chain below rescues it: an empty slug
  # becomes "tag-<id>" (verified collision-free), and the name falls back to the
  # slug and then to "tag-<id>". The nameless-tag assertion then proves no tag was
  # left without a name before we tighten the column to NOT NULL.
  #
  # Rollback restores the table *schema* (empty) and removes the columns; the actual
  # localization rows are recovered from the pre-migration SQL dump, not from down/0.

  def up do
    alter table(:tags) do
      add :name, :string, size: 255
      add :description, :text
    end

    flush()

    backfill =
      case repo().__adapter__() do
        Ecto.Adapters.Postgres ->
          """
          UPDATE tags t
          SET name = tl.name, description = tl.description
          FROM tag_localizations tl
          WHERE tl.tag_id = t.id
          """

        _ ->
          """
          UPDATE tags t
          JOIN tag_localizations tl ON tl.tag_id = t.id
          SET t.name = tl.name, t.description = tl.description
          """
      end

    execute(backfill)

    # Repair any empty slug so the tag stays reachable and can seed the name below.
    execute "UPDATE tags SET slug = CONCAT('tag-', id) WHERE slug IS NULL OR slug = ''"

    # Name fallbacks: typed name -> slug -> synthetic "tag-<id>".
    execute "UPDATE tags SET name = slug WHERE name IS NULL OR name = ''"
    execute "UPDATE tags SET name = CONCAT('tag-', id) WHERE name IS NULL OR name = ''"

    flush()

    %{rows: [[nameless]]} =
      repo().query!("SELECT COUNT(*) FROM tags WHERE name IS NULL OR name = ''")

    if nameless > 0 do
      raise "Aborting migration: #{nameless} tags still have no name after backfill"
    end

    alter table(:tags) do
      modify :name, :string, size: 255, null: false
    end

    drop table(:tag_urls)
    drop table(:tag_synonyms)
    drop table(:tag_closures)
    drop table(:tag_localizations)
  end

  def down do
    create table(:tag_localizations) do
      add :tag_id, references(:tags)
      add :locale_id, references(:locales)
      add :name, :string
      add :description, :string

      timestamps()
    end

    create unique_index(:tag_localizations, [:tag_id, :locale_id], unique: true)

    create table(:tag_synonyms) do
      add :tag_id, references(:tags)
      add :locale_id, references(:locales)
      add :value, :string

      timestamps()
    end

    create unique_index(:tag_synonyms, [:value, :locale_id], unique: true)

    create table(:tag_urls) do
      add :tag_localization_id, references(:tag_localizations)
      add :value, :string
      add :name, :string
      add :description, :string

      timestamps()
    end

    create unique_index(:tag_urls, [:tag_localization_id, :value], unique: true)

    create table(:tag_closures) do
      add :parent_id, references(:tags, on_delete: :nothing)
      add :child_id, references(:tags, on_delete: :nothing)
      add :depth, :integer

      timestamps()
    end

    create unique_index(:tag_closures, [:parent_id, :child_id], unique: true)

    alter table(:tags) do
      remove :name
      remove :description
    end
  end
end
