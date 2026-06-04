defmodule Vutuv.Social.Group do
  @moduledoc false

  use VutuvWeb, :model

  schema "groups" do
    field(:name, :string)
    belongs_to(:user, Vutuv.Accounts.User)
    has_many(:memberships, Vutuv.Social.Membership)

    timestamps()
  end

  @required_fields ~w(name)a
  @optional_fields ~w(user_id)a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @required_fields ++ @optional_fields)
  end
end
