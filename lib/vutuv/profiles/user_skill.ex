defmodule Vutuv.Profiles.UserSkill do
  @moduledoc false

  use VutuvWeb, :model

  schema "user_skills" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:skill, Vutuv.Profiles.Skill)

    has_many(:endorsements, Vutuv.Profiles.Endorsement)

    timestamps()
  end

  @required_fields ~w(user_id skill_id)a
  @optional_fields ~w()a

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned
  with no validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @required_fields ++ @optional_fields)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:skill_id)
    |> unique_constraint(:user_id_skill_id)
  end

  defimpl Phoenix.Param, for: __MODULE__ do
    def to_param(user_skill) do
      Vutuv.Repo.preload(user_skill, [:skill]).skill.slug
    end
  end
end
