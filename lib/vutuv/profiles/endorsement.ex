defmodule Vutuv.Profiles.Endorsement do
  @moduledoc false

  use VutuvWeb, :model

  schema "endorsements" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:user_skill, Vutuv.Profiles.UserSkill)

    timestamps()
  end

  @required_fields ~w(user_id user_skill_id)a
  @optional_fields ~w()a

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned
  with no validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @required_fields ++ @optional_fields)
    |> unique_constraint(:user_id_user_skill_id)
  end
end
