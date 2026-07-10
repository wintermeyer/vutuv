defmodule Vutuv.Companies.CompanyRole do
  @moduledoc """
  A member's role on a company page (issue #929). The claim wizard makes the
  creator an `owner`; the `admin`/`recruiter` grants and the management UI come
  in issue #930. Every role is a proof-derived power, not an employment claim.
  """

  use VutuvWeb, :model

  @roles ~w(owner admin recruiter)

  schema "company_roles" do
    field(:role, :string)

    belongs_to(:company, Vutuv.Companies.Company)
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:granted_by, Vutuv.Accounts.User, foreign_key: :granted_by_user_id)

    timestamps()
  end

  def roles, do: @roles

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:company_id, :user_id, :role, :granted_by_user_id])
    |> validate_required([:company_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:company_id, :user_id])
  end
end
