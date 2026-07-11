defmodule Vutuv.Companies.Company do
  @moduledoc """
  A verified company page (issue #929). A company can only exist once someone
  proved control of its web domain, so edit rights come from a `CompanyDomain`
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

  alias Vutuv.Countries
  alias Vutuv.MarkdownContent
  alias Vutuv.Ssrf

  @derive {Phoenix.Param, key: :slug}

  @statuses ~w(pending active frozen archived)

  schema "companies" do
    field(:name, :string)
    field(:slug, :string)
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
    has_many(:domains, Vutuv.Companies.CompanyDomain)
    has_many(:roles, Vutuv.Companies.CompanyRole)
    has_many(:names, Vutuv.Companies.CompanyName)
    has_many(:images, Vutuv.Companies.CompanyImage)

    timestamps()
  end

  def statuses, do: @statuses

  @doc """
  Claim wizard: identity plus a structured location. City and country are
  required (they are filter keys + JSON-LD values); street and postal code are
  optional, because some countries have no postal-code system at all (Ireland
  pre-Eircode, the UAE, Hong Kong, …) and a small office may not want to publish
  a street. Description and the visibility toggles are set later on the edit form.
  """
  def create_changeset(company, attrs) do
    company
    |> cast(attrs, [:name, :website_url, :street_address, :zip_code, :city, :state, :country])
    |> validate_required([:name, :city, :country])
    |> shared_validations()
  end

  @doc "Owner edit: the wizard fields minus verification, plus description + toggles + logo."
  def edit_changeset(company, attrs) do
    company
    |> cast(attrs, [
      :name,
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
    |> validate_required([:name, :city, :country])
    |> validate_length(:description, max: 10_000)
    |> MarkdownContent.validate_no_images(:description)
    |> shared_validations()
  end

  @doc "Moves the lifecycle status. Stamping `verified_at` lives in the context (`activate/2`)."
  def status_changeset(company, status) when status in @statuses do
    change(company, status: status)
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
