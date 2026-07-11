defmodule Vutuv.Companies.CompanyName do
  @moduledoc """
  An alternative name a verified company is findable under (issue #930). Solves
  the findability problem (#851): a company that trades under several names (its
  registered name vs. a product brand) is findable under all of them — the
  directory and admin search match names AND aliases.

  `kind`:

    * `alias` — a general alternative name.
    * `former` — the previous name after a rename (rename history is data, not a
      log file: `Companies.update_company/2` auto-appends the old name here).
    * `brand` — a product / trading brand.
    * `abbreviation` — a short form.

  `flagged_at` is the collision guardrail: an alias equal (case-insensitive) to
  another verified company's name or alias is stored but stamped here for the
  admin queue instead of silently accepted — a human looks at every flag quietly
  (there is deliberately no user-facing warning; identical company names are
  common and legitimate). See `Vutuv.Companies.add_alias/3`.
  """

  use VutuvWeb, :model

  @kinds ~w(alias former brand abbreviation)

  schema "company_names" do
    field(:name, :string)
    field(:kind, :string, default: "alias")
    field(:flagged_at, :naive_datetime)

    belongs_to(:company, Vutuv.Companies.Company)

    timestamps()
  end

  def kinds, do: @kinds

  def changeset(company_name, attrs) do
    company_name
    |> cast(attrs, [:company_id, :name, :kind, :flagged_at])
    |> update_change(:name, &trim/1)
    |> validate_required([:company_id, :name, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint([:company_id, :name],
      name: :company_names_company_lower_name_index,
      message: "is already listed for this company"
    )
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
