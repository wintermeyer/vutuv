defmodule Vutuv.Organizations.OrganizationLike do
  @moduledoc false

  use VutuvWeb, :model

  schema "organization_likes" do
    belongs_to(:organization, Vutuv.Organizations.Organization)
    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end
end
