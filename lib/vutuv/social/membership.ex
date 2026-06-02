defmodule Vutuv.Social.Membership do
  @moduledoc false

  use VutuvWeb, :model

  schema "memberships" do
    belongs_to(:connection, Vutuv.Social.Connection)
    belongs_to(:group, Vutuv.Social.Group)

    timestamps()
  end

  @required_fields ~w(connection_id group_id)a
  @optional_fields ~w()a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @required_fields ++ @optional_fields)
  end
end
