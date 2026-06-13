defmodule Vutuv.Social.Membership do
  @moduledoc false

  use VutuvWeb, :model

  schema "memberships" do
    belongs_to(:follow, Vutuv.Social.Follow)
    belongs_to(:group, Vutuv.Social.Group)

    timestamps()
  end

  # :follow_id is set programmatically (build_assoc from the URL-scoped,
  # ownership-checked follow) and must not be castable from the form.
  @required_fields ~w(group_id)a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @required_fields)
    |> validate_required(@required_fields)
  end
end
