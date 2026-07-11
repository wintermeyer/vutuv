defmodule Vutuv.Accounts.ViewerExclusion do
  @moduledoc """
  One entry on a member's viewer-exclusion list (issue #938, "Ausschlussliste").
  The list is a general per-member "these viewers never see my
  visibility-gated info" set, subtracted as the last step of the visibility
  gate (subtracting never adds). It is wired first only to the #928 job-search
  fields (employment status + salary expectation) through
  `Vutuv.Accounts.viewer_excluded?/2`; other visibility-gated fields can
  opt into the same list later without a new table.

  Each row names exactly ONE excluded target:

    * a **member** account (`excluded_user_id`) — your boss, a colleague;
    * an email **domain** (`domain`) — any signed-in viewer whose confirmed
      email is at that domain **or any subdomain of it** (`example.com` also
      matches `eu.example.com`).

  Beyond the list, a full **block** (`Vutuv.Social.block_user`) implies the same
  exclusion, resolved in `Vutuv.Accounts.viewer_excluded?/2` — so the owner
  never keeps two lists for one person. Organizations (issue #929, verified organization
  pages) can join later as a third nullable target. Rows are built through
  `Vutuv.Accounts` (never from raw user params for the member target, whose id
  is set programmatically); the domain is the only user-written field.
  """

  use VutuvWeb, :model

  alias Vutuv.Accounts.User

  # A bare hostname: lowercase labels of letters/digits/hyphens, at least two
  # labels (one dot), each label 1-63 chars, whole name <= 253. No scheme, no
  # path, no `@` — those are stripped by normalize_domain/1 before validation.
  @domain_format ~r/^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/

  schema "viewer_exclusions" do
    field(:domain, :string)
    belongs_to(:user, User)
    belongs_to(:excluded_user, User)

    timestamps(updated_at: false)
  end

  @doc """
  Excludes a specific member account. `user_id`/`excluded_user_id` are set
  programmatically (never cast), a member can't exclude themselves, and the
  partial unique index keeps the same person from being added twice.
  """
  def member_changeset(%User{} = owner, %User{} = excluded) do
    %__MODULE__{}
    |> change(user_id: owner.id, excluded_user_id: excluded.id)
    |> validate_not_self()
    |> assoc_constraint(:excluded_user)
    |> unique_constraint(:excluded_user_id,
      name: :viewer_exclusions_user_id_excluded_user_id_index,
      message: "is already on your list"
    )
  end

  @doc """
  Excludes an email domain. The domain is the one user-written value: it is
  normalized (lowercased, scheme/path/`@` stripped) and must be a bare
  hostname. `user_id` is set programmatically; the partial unique index keeps
  the same domain from being added twice.
  """
  def domain_changeset(%User{} = owner, params) do
    %__MODULE__{}
    |> cast(params, [:domain])
    |> update_change(:domain, &normalize_domain/1)
    |> validate_required([:domain])
    # varchar(255) column: an oversized value must fail as a changeset error,
    # never a raised Postgres 22001.
    |> validate_length(:domain, max: 255)
    |> validate_format(:domain, @domain_format,
      message: "must be a domain like example.com, without http:// or a path"
    )
    |> change(user_id: owner.id)
    |> unique_constraint(:domain,
      name: :viewer_exclusions_user_id_domain_index,
      message: "is already on your list"
    )
  end

  defp validate_not_self(changeset) do
    if get_field(changeset, :user_id) == get_field(changeset, :excluded_user_id) do
      add_error(changeset, :excluded_user_id, "cannot exclude yourself")
    else
      changeset
    end
  end

  # Be forgiving about what the member pastes: a full URL, a `user@host`
  # address or a stray space should still resolve to the bare host, so the
  # editor accepts the common shapes and the format validation only rejects
  # what genuinely is not a domain.
  defp normalize_domain(nil), do: nil

  defp normalize_domain(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r{^[a-z][a-z0-9+.-]*://}, "")
    |> String.split("/", parts: 2)
    |> List.first()
    |> String.split("@")
    |> List.last()
    |> String.trim(".")
  end
end
