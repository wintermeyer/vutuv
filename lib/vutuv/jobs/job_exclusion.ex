defmodule Vutuv.Jobs.JobExclusion do
  @moduledoc """
  One entry on a job posting's — or a verified organization's standing default —
  exclusion list (issue #939), the poster-side twin of the member exclusion list
  (`Vutuv.Accounts.ViewerExclusion`, issue #938). Each row subtracts ONE viewer
  group from ONE subject, as the last step of the posting's visibility gate
  (subtracting never adds).

  **Subject** (exactly one, set programmatically): a single `job_posting`'s own
  list, or an `organization`'s standing default that every posting attributed to
  it inherits.

  **Target dimension** (exactly one): an excluded `excluded_user` (a member), an
  excluded `excluded_organization` (its verified domains, its role holders and
  members whose current work experience links to it), or an email `domain`
  (that domain and any subdomain of it).

  Rows are built through `Vutuv.Jobs.Exclusions` (never from raw params for the
  subject/member/organization ids, which are set programmatically); the domain is
  the only user-written field. Matching lives in `Vutuv.Jobs.Exclusions`, not
  here, so there is one predicate per side.
  """

  use VutuvWeb, :model

  alias Vutuv.Accounts.User
  alias Vutuv.EmailDomain
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Organizations.Organization

  schema "job_exclusions" do
    field(:domain, :string)

    belongs_to(:job_posting, JobPosting)
    belongs_to(:organization, Organization)
    belongs_to(:excluded_user, User)
    belongs_to(:excluded_organization, Organization)

    timestamps(updated_at: false)
  end

  @doc """
  Excludes a specific member account from `subject` (`%{job_posting_id: id}` or
  `%{organization_id: id}`). The ids are set programmatically; the partial unique
  index keeps the same member from being added twice.
  """
  def member_changeset(subject, %User{} = excluded) when is_map(subject) do
    %__MODULE__{}
    |> change(Map.put(subject, :excluded_user_id, excluded.id))
    |> assoc_constraint(:excluded_user)
    |> unique_constraint(:excluded_user_id,
      name: unique_name(subject, :member),
      message: "is already on this list"
    )
  end

  @doc """
  Excludes a whole organization (its verified domains, role holders and current
  staff) from `subject`. Ids set programmatically; deduped by the partial index.
  """
  def organization_changeset(subject, %Organization{} = excluded) when is_map(subject) do
    %__MODULE__{}
    |> change(Map.put(subject, :excluded_organization_id, excluded.id))
    |> assoc_constraint(:excluded_organization)
    |> unique_constraint(:excluded_organization_id,
      name: unique_name(subject, :organization),
      message: "is already on this list"
    )
  end

  @doc """
  Excludes an email domain from `subject`. The domain is the one user-written
  value: normalized (lowercased, scheme/path/`@` stripped) and validated as a
  bare hostname. The partial unique index keeps the same domain from being added
  twice.
  """
  def domain_changeset(subject, params) when is_map(subject) do
    %__MODULE__{}
    |> cast(params, [:domain])
    |> update_change(:domain, &EmailDomain.normalize/1)
    |> validate_required([:domain])
    # varchar(255) column: an oversized value must fail as a changeset error,
    # never a raised Postgres 22001.
    |> validate_length(:domain, max: 255)
    |> validate_format(:domain, EmailDomain.format(),
      message: "must be a domain like example.com, without http:// or a path"
    )
    |> change(subject)
    |> unique_constraint(:domain,
      name: unique_name(subject, :domain),
      message: "is already on this list"
    )
  end

  # The partial unique index for a given subject × dimension (see the migration).
  defp unique_name(%{job_posting_id: _}, :member), do: :job_exclusions_posting_member
  defp unique_name(%{job_posting_id: _}, :organization), do: :job_exclusions_posting_org
  defp unique_name(%{job_posting_id: _}, :domain), do: :job_exclusions_posting_domain
  defp unique_name(%{organization_id: _}, :member), do: :job_exclusions_org_member
  defp unique_name(%{organization_id: _}, :organization), do: :job_exclusions_org_org
  defp unique_name(%{organization_id: _}, :domain), do: :job_exclusions_org_domain
end
