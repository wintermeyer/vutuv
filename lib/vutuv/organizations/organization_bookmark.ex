defmodule Vutuv.Organizations.OrganizationBookmark do
  @moduledoc false

  use VutuvWeb, :model

  schema "organization_bookmarks" do
    belongs_to(:organization, Vutuv.Organizations.Organization)
    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end
end
