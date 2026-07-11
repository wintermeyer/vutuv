defmodule Vutuv.Organizations.OrganizationDomain do
  @moduledoc """
  A verified (or being-verified) domain of an organization (issue #929). The unique
  `domain` column is the anti-squatting anchor: one domain belongs to exactly
  one organization. Domain identity is the **exact host** (`sub.example.com` and
  `example.com` are distinct), so no public-suffix list is involved.

  Two proof `method`s, both proving control of the DOMAIN itself (never merely
  an address on it, which is why there is no e-mail method: anyone with a
  `@gmail.com` address could otherwise claim the gmail.com page):

    * `dns` — a `vutuv-organization-verify=<token>` TXT record on the domain.
    * `well_known` — the token served at
      `https://domain/.well-known/vutuv-organization-verify.txt`.

  Both are re-checked periodically; a failure starts a `grace_deadline_at`
  window before the domain loses verified status.
  """

  use VutuvWeb, :model

  alias Vutuv.Ssrf

  @methods ~w(dns well_known)

  schema "organization_domains" do
    field(:domain, :string)
    field(:primary?, :boolean, default: false)
    field(:method, :string)
    field(:verification_token, :string)
    field(:verified_at, :naive_datetime)
    field(:last_checked_at, :naive_datetime)
    field(:grace_deadline_at, :naive_datetime)

    belongs_to(:organization, Vutuv.Organizations.Organization)

    timestamps()
  end

  def methods, do: @methods

  @doc """
  Casts a claimed domain. `domain` is normalized to a bare lowercase host
  (scheme/path/port stripped, `www.` kept — exact host). The literal SSRF
  check runs here (no DNS in a changeset); the fetch-time guard runs in the
  verifier.
  """
  def changeset(domain, attrs) do
    domain
    |> cast(attrs, [
      :organization_id,
      :domain,
      :primary?,
      :method,
      :verification_token,
      :verified_at,
      :last_checked_at,
      :grace_deadline_at
    ])
    |> update_change(:domain, &normalize/1)
    |> validate_required([:domain, :method, :verification_token])
    |> validate_inclusion(:method, @methods)
    |> validate_length(:domain, max: 255)
    |> validate_domain()
    |> unique_constraint(:domain)
  end

  @doc "Records the outcome of a periodic re-check (or a fresh verification)."
  def check_changeset(domain, attrs) do
    cast(domain, attrs, [:verified_at, :last_checked_at, :grace_deadline_at])
  end

  @doc """
  Reduces a URL-or-bare-host to a bare lowercase host: strips scheme, path,
  query and port; keeps the exact host (no `www.` stripping). Used by the
  changeset and by the claim wizard to derive the domain from the website URL.
  """
  def normalize(nil), do: nil

  def normalize(value) do
    trimmed = value |> to_string() |> String.trim() |> String.downcase()

    host =
      if String.contains?(trimmed, "://") do
        URI.parse(trimmed).host
      else
        trimmed |> String.split("/", parts: 2) |> List.first()
      end

    (host || trimmed)
    |> String.split(":", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.trim_trailing(".")
  end

  # A real DNS name (at least one dot, valid label characters) that is not an
  # SSRF target (rejects IP literals and localhost).
  defp validate_domain(changeset) do
    case get_field(changeset, :domain) do
      nil ->
        changeset

      domain ->
        cond do
          not Regex.match?(
            ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/,
            domain
          ) ->
            add_error(changeset, :domain, "is not a valid domain")

          Ssrf.internal_host?(domain) ->
            add_error(changeset, :domain, "is not an allowed domain")

          true ->
            changeset
        end
    end
  end
end
