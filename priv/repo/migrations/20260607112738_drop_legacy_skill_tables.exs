defmodule Vutuv.Repo.Migrations.DropLegacySkillTables do
  use Ecto.Migration

  # The 2017 skills->tags migration (20170124150031) moved this data into
  # tags / user_tags / user_tag_endorsements, but the source tables were never
  # dropped and no schema or query has referenced them since. They still hold
  # integer FKs into users and skills, which would block the UUID v7 id
  # conversion that follows this migration. The pre-deploy pg_dump keeps an
  # archive copy (see DEPLOY_TODO.md).

  def up do
    # Dead columns on live tables, left behind by the skills/companies era.
    # Dropping a column drops its FK constraint with it.
    alter table(:search_terms) do
      remove(:skill_id)
    end

    alter table(:search_query_results) do
      remove(:skill_id)
    end

    alter table(:work_experiences) do
      remove(:company_id)
    end

    # Children before parents (endorsements -> user_skills -> skills).
    drop(table(:endorsements))
    drop(table(:user_skills))
    drop(table(:skill_synonyms))
    drop(table(:skills))
    drop(table(:companies))
    drop(table(:data_enrichments))
    drop(table(:fullcontact_caches))
  end

  def down do
    raise Ecto.MigrationError,
      message: "irreversible: restore the legacy skill tables from the pre-deploy pg_dump"
  end
end
