defmodule Vutuv.Repo.Migrations.CreateCompanyNames do
  use Ecto.Migration

  # Alternative names a verified company is findable under (issue #930): the
  # registered name vs. a product brand, an abbreviation, or the former name
  # kept as rename history. `flagged_at` is the collision guardrail: an alias
  # equal (case-insensitive) to another verified company's name or alias is
  # stored but flagged for the admin queue instead of silently accepted.
  def change do
    create table(:company_names) do
      add(:company_id, references(:companies, on_delete: :delete_all, type: :binary_id),
        null: false
      )

      add(:name, :string, null: false)
      add(:kind, :string, null: false, default: "alias")
      add(:flagged_at, :naive_datetime)

      timestamps()
    end

    create(index(:company_names, [:company_id]))
    # Case-insensitive lookup for the directory / admin search (name OR alias)
    # and the collision guardrail's "does this name already exist" probe.
    create(index(:company_names, ["lower(name)"], name: :company_names_lower_name_index))
    create(index(:company_names, [:flagged_at]))
    # An alias is unique per company (no duplicate "brand" rows), but the same
    # name may legitimately be an alias of several different companies.
    create(unique_index(:company_names, [:company_id, "lower(name)"], name: :company_names_company_lower_name_index))
  end
end
