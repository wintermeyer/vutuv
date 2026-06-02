defmodule Vutuv.Accounts.OAuthProvider do
  @moduledoc false

  use VutuvWeb, :model

  schema "oauth_providers" do
    field(:provider_id, :string)
    field(:provider, :string)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [:provider_id, :provider])
  end
end
