defmodule Vutuv.Companies.CompanyBookmark do
  @moduledoc false

  use VutuvWeb, :model

  schema "company_bookmarks" do
    belongs_to(:company, Vutuv.Companies.Company)
    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end
end
