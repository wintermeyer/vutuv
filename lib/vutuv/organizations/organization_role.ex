defmodule Vutuv.Organizations.OrganizationRole do
  @moduledoc """
  A member's role on an organization page (issue #929). The claim wizard makes the
  creator an `owner`; the `admin`/`recruiter` grants and the management UI come
  in issue #930. Every role is a proof-derived power, not an employment claim.
  """

  use VutuvWeb, :model

  @roles ~w(owner admin recruiter)

  schema "organization_roles" do
    field(:role, :string)

    belongs_to(:organization, Vutuv.Organizations.Organization)
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:granted_by, Vutuv.Accounts.User, foreign_key: :granted_by_user_id)

    timestamps()
  end

  def roles, do: @roles

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:organization_id, :user_id, :role, :granted_by_user_id])
    |> validate_required([:organization_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:organization_id, :user_id])
  end
end
