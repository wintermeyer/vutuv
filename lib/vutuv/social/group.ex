defmodule Vutuv.Social.Group do
  @moduledoc false

  use VutuvWeb, :model

  schema "groups" do
    field(:name, :string)
    belongs_to(:user, Vutuv.Accounts.User)
    has_many(:memberships, Vutuv.Social.Membership)

    timestamps()
  end

  # :user_id is set programmatically (build_assoc from the session user) and
  # must not be castable — castable, a form field could re-home the group.
  @required_fields ~w(name)a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @required_fields)
    |> validate_required(@required_fields)
  end
end
