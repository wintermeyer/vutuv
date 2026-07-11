defmodule Vutuv.Repo.Migrations.RenameCompaniesToOrganizations do
  use Ecto.Migration

  # Rename the whole "company" domain to "organization": a Verein, a Behörde, the
  # UN or the Bundestag are organizations, not companies, so nobody has to sign
  # up as a "company". Tables, FK columns, indexes and constraints are renamed
  # together so Ecto's computed constraint names keep matching the DB (Postgres
  # does NOT rename indexes/constraints when a table is renamed). Plus the new
  # required `kind` (Art: Unternehmen | Verein | Behörde | Hochschule | NGO |
  # Sonstige); existing rows backfill to "company" via the column default.
  #
  # NOT N-1 compatible: the still-deployed old release keeps querying `companies`
  # and 500s on those queries until nginx switches slots. A deliberate single
  # planned deploy agreed beforehand — a brief blip on the 3-day-old /companies
  # feature during the switch window, acceptable because it carries next to no
  # data yet.

  @tables [
    {:companies, :organizations},
    {:company_domains, :organization_domains},
    {:company_roles, :organization_roles},
    {:company_images, :organization_images},
    {:company_names, :organization_names},
    {:company_likes, :organization_likes},
    {:company_bookmarks, :organization_bookmarks}
  ]

  # Tables holding a `company_id` column that becomes `organization_id`. Postgres
  # rewrites dependent partial-index predicates and the handles CHECK expression
  # to the new column name automatically on rename.
  @id_columns [
    :organization_domains,
    :organization_roles,
    :organization_images,
    :organization_names,
    :organization_likes,
    :organization_bookmarks,
    :work_experiences,
    :handles
  ]

  # {old_name, new_name}. Renamed by name (index names are independent of table
  # names in Postgres). The five the code checks by name (unique_constraint /
  # foreign_key on domain, role, name, handle-owner, work-experience) are in here;
  # the rest are renamed only for consistency.
  @indexes [
    {"companies_slug_index", "organizations_slug_index"},
    {"companies_status_index", "organizations_status_index"},
    {"companies_created_by_user_id_index", "organizations_created_by_user_id_index"},
    {"companies_city_index", "organizations_city_index"},
    {"company_domains_domain_index", "organization_domains_domain_index"},
    {"company_domains_company_id_index", "organization_domains_organization_id_index"},
    {"company_domains_one_primary_index", "organization_domains_one_primary_index"},
    {"company_roles_company_id_user_id_index", "organization_roles_organization_id_user_id_index"},
    {"company_roles_user_id_index", "organization_roles_user_id_index"},
    {"company_images_token_index", "organization_images_token_index"},
    {"company_images_company_id_index", "organization_images_organization_id_index"},
    {"company_images_inserted_at_index", "organization_images_inserted_at_index"},
    {"company_names_company_id_index", "organization_names_organization_id_index"},
    {"company_names_flagged_at_index", "organization_names_flagged_at_index"},
    {"company_names_lower_name_index", "organization_names_lower_name_index"},
    {"company_names_company_lower_name_index", "organization_names_organization_lower_name_index"},
    {"company_likes_company_id_user_id_index", "organization_likes_organization_id_user_id_index"},
    {"company_likes_user_id_inserted_at_index", "organization_likes_user_id_inserted_at_index"},
    {"company_likes_company_id_index", "organization_likes_organization_id_index"},
    {"company_bookmarks_company_id_user_id_index", "organization_bookmarks_organization_id_user_id_index"},
    {"company_bookmarks_user_id_inserted_at_index", "organization_bookmarks_user_id_inserted_at_index"},
    {"company_bookmarks_company_id_index", "organization_bookmarks_organization_id_index"},
    {"work_experiences_company_id_index", "work_experiences_organization_id_index"},
    {"handles_company_id_index", "handles_organization_id_index"}
  ]

  # {new_table, old_constraint, new_constraint}. Renaming a PK/unique constraint
  # renames its backing index too, so this also cleans up the *_pkey index names.
  @constraints [
    {:organizations, "companies_pkey", "organizations_pkey"},
    {:organizations, "companies_created_by_user_id_fkey", "organizations_created_by_user_id_fkey"},
    {:organization_domains, "company_domains_pkey", "organization_domains_pkey"},
    {:organization_domains, "company_domains_company_id_fkey", "organization_domains_organization_id_fkey"},
    {:organization_roles, "company_roles_pkey", "organization_roles_pkey"},
    {:organization_roles, "company_roles_company_id_fkey", "organization_roles_organization_id_fkey"},
    {:organization_roles, "company_roles_user_id_fkey", "organization_roles_user_id_fkey"},
    {:organization_roles, "company_roles_granted_by_user_id_fkey", "organization_roles_granted_by_user_id_fkey"},
    {:organization_images, "company_images_pkey", "organization_images_pkey"},
    {:organization_images, "company_images_company_id_fkey", "organization_images_organization_id_fkey"},
    {:organization_images, "company_images_user_id_fkey", "organization_images_user_id_fkey"},
    {:organization_names, "company_names_pkey", "organization_names_pkey"},
    {:organization_names, "company_names_company_id_fkey", "organization_names_organization_id_fkey"},
    {:organization_likes, "company_likes_pkey", "organization_likes_pkey"},
    {:organization_likes, "company_likes_company_id_fkey", "organization_likes_organization_id_fkey"},
    {:organization_likes, "company_likes_user_id_fkey", "organization_likes_user_id_fkey"},
    {:organization_bookmarks, "company_bookmarks_pkey", "organization_bookmarks_pkey"},
    {:organization_bookmarks, "company_bookmarks_company_id_fkey", "organization_bookmarks_organization_id_fkey"},
    {:organization_bookmarks, "company_bookmarks_user_id_fkey", "organization_bookmarks_user_id_fkey"},
    {:work_experiences, "work_experiences_company_id_fkey", "work_experiences_organization_id_fkey"},
    {:handles, "handles_company_id_fkey", "handles_organization_id_fkey"}
  ]

  def up do
    Enum.each(@tables, fn {old, new} -> rename(table(old), to: table(new)) end)
    Enum.each(@id_columns, fn t -> rename(table(t), :company_id, to: :organization_id) end)
    Enum.each(@indexes, fn {old, new} -> execute("ALTER INDEX #{old} RENAME TO #{new}") end)

    Enum.each(@constraints, fn {t, old, new} ->
      execute("ALTER TABLE #{t} RENAME CONSTRAINT #{old} TO #{new}")
    end)

    alter table(:organizations) do
      # The kind of organization (Art). Required going forward via the claim
      # wizard; existing rows backfill to "company" through this default, which
      # also lets the still-deployed old release keep inserting during the switch.
      add(:kind, :string, null: false, default: "company")
    end

    create(index(:organizations, [:kind]))
  end

  def down do
    drop(index(:organizations, [:kind]))

    alter table(:organizations) do
      remove(:kind)
    end

    Enum.each(@constraints, fn {t, old, new} ->
      execute("ALTER TABLE #{t} RENAME CONSTRAINT #{new} TO #{old}")
    end)

    @indexes
    |> Enum.reverse()
    |> Enum.each(fn {old, new} -> execute("ALTER INDEX #{new} RENAME TO #{old}") end)

    Enum.each(@id_columns, fn t -> rename(table(t), :organization_id, to: :company_id) end)
    @tables |> Enum.reverse() |> Enum.each(fn {old, new} -> rename(table(new), to: table(old)) end)
  end
end
