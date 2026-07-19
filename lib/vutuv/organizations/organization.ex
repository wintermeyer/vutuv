defmodule Vutuv.Organizations.Organization do
  @moduledoc """
  A verified organization page (issue #929). An organization can only exist once someone
  proved control of its web domain, so edit rights come from a `OrganizationDomain`
  verification, never from a self-asserted employment claim.

  `status` is the lifecycle: `pending` (claimed, not yet verified), `active`
  (at least one verified domain, publicly listed), `frozen` (hidden by
  moderation, visible to owner + admins) and `archived`. `seo?`/`geo?` are the
  owner's machine-visibility toggles (same semantics as a member's
  `noindex?`/`noai?`). `country` is an ISO 3166-1 alpha-2 code
  (`Vutuv.Countries`), not a display name, because it is a filter key and a
  JSON-LD value.
  """

  use VutuvWeb, :model

  # The `gettext/1` macro (not available in the shared `:model` block) so the
  # kind (Art) labels are picked up by `mix gettext.extract`; a plain
  # `Gettext.gettext/2` runtime call would never be extracted.
  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Countries
  alias Vutuv.MarkdownContent
  alias Vutuv.Ssrf

  @derive {Phoenix.Param, key: :slug}

  @statuses ~w(pending active frozen archived)

  # The kind of organization (Art). An organization is NOT necessarily a company:
  # a Verein, a Behörde, the UN or the Bundestag are organizations too, so nobody
  # has to sign up as a "company". Chosen in the claim wizard (required), shown as
  # a badge, filterable, and mapped to a schema.org `@type`. Display order is this
  # list's order. `:company` is the migration backfill for pre-existing rows.
  @kinds ~w(company association government education ngo other)a

  schema "organizations" do
    field(:name, :string)
    # No field default on purpose: the claim wizard must force an active choice
    # (a blank submit fails cast), while the DB column defaults to "company" only
    # to backfill the rows that existed before this field.
    field(:kind, Ecto.Enum, values: @kinds)
    field(:slug, :string)
    # The opt-in root handle (issue #941): the organization's `@name` in the shared
    # member/organization namespace, reachable at `/:username`. nil = no root URL
    # (still reachable at `/organizations/:slug`). Uniqueness across members and
    # organizations lives in the `handles` registry, not a per-table index; the
    # grammar mirrors a member username (`Vutuv.Handles.validate_handle/2`).
    field(:username, :string)
    field(:description, :string)
    field(:website_url, :string)
    field(:logo, :string)
    field(:cover, :string)
    field(:street_address, :string)
    field(:zip_code, :string)
    field(:city, :string)
    field(:state, :string)
    field(:country, :string)
    field(:seo?, :boolean, default: true)
    field(:geo?, :boolean, default: true)
    field(:status, :string, default: "pending")
    field(:verified_at, :naive_datetime)
    field(:frozen_at, :naive_datetime)

    belongs_to(:created_by, Vutuv.Accounts.User, foreign_key: :created_by_user_id)
    has_many(:domains, Vutuv.Organizations.OrganizationDomain)
    has_many(:roles, Vutuv.Organizations.OrganizationRole)
    has_many(:names, Vutuv.Organizations.OrganizationName)
    has_many(:images, Vutuv.Organizations.OrganizationImage)

    timestamps()
  end

  def statuses, do: @statuses

  @doc "The organization kinds (Art), in display order."
  def kinds, do: @kinds

  @doc """
  The human label for a kind (Art), the single source shared by the claim
  wizard's select, the profile/page badge and the agent docs. English source
  strings so they can never collide with the ad billing "Company" label; the
  German translations live in the `.po`.
  """
  def kind_label(:company), do: gettext("Business")
  def kind_label(:association), do: gettext("Association")
  def kind_label(:government), do: gettext("Public authority")
  def kind_label(:education), do: gettext("Education / research")
  def kind_label(:ngo), do: gettext("NGO / foundation")
  def kind_label(:other), do: gettext("Other organization")
  def kind_label(kind) when is_binary(kind), do: kind_label(String.to_existing_atom(kind))
  def kind_label(_), do: nil

  @doc "`{label, value}` pairs for the wizard's kind select, in display order."
  def kind_options, do: Enum.map(@kinds, &{kind_label(&1), &1})

  @doc """
  The schema.org `@type` for a kind, so the JSON-LD calls a Behörde a
  `GovernmentOrganization` and a university an `EducationalOrganization` rather
  than a plain `Organization`. Everything else that has no closer type is a plain
  `Organization`.
  """
  def schema_org_type(:company), do: "Corporation"
  def schema_org_type(:government), do: "GovernmentOrganization"
  def schema_org_type(:education), do: "EducationalOrganization"
  def schema_org_type(:ngo), do: "NGO"
  def schema_org_type(kind) when kind in [:association, :other], do: "Organization"

  def schema_org_type(kind) when is_binary(kind),
    do: schema_org_type(String.to_existing_atom(kind))

  def schema_org_type(_), do: "Organization"

  @doc """
  Claim wizard: identity, the kind (Art) and a structured location. Kind, city
  and country are required (they are filter keys + JSON-LD values); street and
  postal code are optional, because some countries have no postal-code system at
  all (Ireland pre-Eircode, the UAE, Hong Kong, …) and a small office may not
  want to publish a street. Description and the visibility toggles are set later
  on the edit form.
  """
  def create_changeset(organization, attrs) do
    organization
    |> cast(attrs, [
      :name,
      :kind,
      :website_url,
      :street_address,
      :zip_code,
      :city,
      :state,
      :country
    ])
    |> validate_required([:name, :kind, :city, :country])
    |> shared_validations()
  end

  @doc "Owner edit: the wizard fields minus verification, plus description + toggles + logo."
  def edit_changeset(organization, attrs) do
    organization
    |> cast(attrs, [
      :name,
      :kind,
      :description,
      :website_url,
      :street_address,
      :zip_code,
      :city,
      :state,
      :country,
      :seo?,
      :geo?,
      :logo
    ])
    |> validate_required([:name, :kind, :city, :country])
    |> validate_length(:description, max: 10_000)
    |> MarkdownContent.validate_no_images(:description)
    |> shared_validations()
  end

  @doc "Moves the lifecycle status. Stamping `verified_at` lives in the context (`activate/2`)."
  def status_changeset(organization, status) when status in @statuses do
    change(organization, status: status)
  end

  @doc """
  Claims (or clears) the opt-in root handle (issue #941). The grammar is the
  member-username grammar (`Vutuv.Handles.validate_handle/2`), so an organization
  handle is indistinguishable from a member handle and can never format-collide.
  Global uniqueness is enforced by the `handles` registry row that
  `Vutuv.Organizations.claim_handle/2` upserts in the same transaction, so no
  uniqueness check lives here.
  """
  def handle_changeset(organization, attrs) do
    organization
    |> cast(attrs, [:username])
    |> validate_required(:username)
    |> Vutuv.Handles.validate_handle(:username)
    # A handle already linked from a post can't be claimed here either.
    |> Vutuv.Mentions.validate_handle_available(:username)
  end

  defp shared_validations(changeset) do
    changeset
    |> update_change(:name, &trim/1)
    |> update_change(:street_address, &trim/1)
    |> update_change(:zip_code, &trim/1)
    |> update_change(:city, &trim/1)
    |> update_change(:state, &trim_to_nil/1)
    |> update_change(:country, &upcase/1)
    |> update_change(:website_url, &trim_to_nil/1)
    |> validate_length(:name, max: 255)
    |> validate_length(:street_address, max: 255)
    |> validate_length(:zip_code, max: 32)
    |> validate_length(:city, max: 255)
    |> validate_length(:state, max: 255)
    |> validate_length(:website_url, max: 255)
    |> validate_length(:logo, max: 255)
    |> validate_country()
    |> validate_website_url()
  end

  defp validate_country(changeset) do
    validate_change(changeset, :country, fn :country, code ->
      if Countries.valid?(code), do: [], else: [country: "is not a valid country"]
    end)
  end

  # Optional. A stored URL is fetched server-side for the well-known verification
  # method, so the literal SSRF check (no DNS in a changeset) runs here too.
  defp validate_website_url(changeset) do
    case get_change(changeset, :website_url) do
      nil ->
        changeset

      url ->
        uri = URI.parse(url)

        cond do
          uri.scheme not in ["http", "https"] ->
            add_error(changeset, :website_url, "must start with http:// or https://")

          is_nil(uri.host) or uri.host == "" ->
            add_error(changeset, :website_url, "is not a valid URL")

          Ssrf.internal_host?(uri.host) ->
            add_error(changeset, :website_url, "is not an allowed address")

          true ->
            changeset
        end
    end
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)

  defp trim_to_nil(nil), do: nil

  defp trim_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp upcase(nil), do: nil
  defp upcase(value), do: value |> String.trim() |> String.upcase()
end
