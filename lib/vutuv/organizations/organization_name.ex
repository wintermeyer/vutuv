defmodule Vutuv.Organizations.OrganizationName do
  @moduledoc """
  An alternative name a verified organization is findable under (issue #930). Solves
  the findability problem (#851): an organization that trades under several names (its
  registered name vs. a product brand) is findable under all of them — the
  directory and admin search match names AND aliases.

  `kind`:

    * `alias` — a general alternative name.
    * `former` — the previous name after a rename (rename history is data, not a
      log file: `Organizations.update_organization/2` auto-appends the old name here).
    * `brand` — a product / trading brand.
    * `abbreviation` — a short form.

  `flagged_at` is the collision guardrail: an alias equal (case-insensitive) to
  another verified organization's name or alias is stored but stamped here for the
  admin queue instead of silently accepted — a human looks at every flag quietly
  (there is deliberately no user-facing warning; identical organization names are
  common and legitimate). See `Vutuv.Organizations.add_alias/3`.
  """

  use VutuvWeb, :model

  @kinds ~w(alias former brand abbreviation)

  schema "organization_names" do
    field(:name, :string)
    field(:kind, :string, default: "alias")
    field(:flagged_at, :naive_datetime)

    belongs_to(:organization, Vutuv.Organizations.Organization)

    timestamps()
  end

  def kinds, do: @kinds

  def changeset(organization_name, attrs) do
    organization_name
    |> cast(attrs, [:organization_id, :name, :kind, :flagged_at])
    |> update_change(:name, &trim/1)
    |> validate_required([:organization_id, :name, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint([:organization_id, :name],
      name: :organization_names_organization_lower_name_index,
      message: "is already listed for this organization"
    )
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
end
