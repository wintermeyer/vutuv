defmodule Vutuv.Profiles.Skill do
  @moduledoc false

  use VutuvWeb, :model
  @derive {Phoenix.Param, key: :slug}

  schema "skills" do
    field(:name, :string)
    field(:downcase_name, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:url, :string)

    has_many(:user_skills, Vutuv.Profiles.UserSkill)

    timestamps()
  end

  @required_fields ~w(name)a
  @optional_fields ~w(downcase_name slug description url)a

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned
  with no validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @required_fields ++ @optional_fields)
    |> validate_required([:name])
    |> validate_length(:name, max: 45)
    |> put_downcase_if_name_changed(model)
    |> unique_constraint(:downcase_name)
    |> unique_constraint(:slug)
  end

  defp put_downcase_if_name_changed(changeset, _model) do
    changeset
    |> get_change(:name)
    |> case do
      nil ->
        changeset

      name ->
        changeset
        |> put_change(:slug, Vutuv.SlugHelpers.gen_slug_unique(%__MODULE__{name: name}, :slug))
        |> put_change(:downcase_name, String.downcase(name))
    end
  end

  defimpl String.Chars, for: __MODULE__ do
    def to_string(skill), do: "#{skill.name}"
  end

  defimpl List.Chars, for: __MODULE__ do
    def to_charlist(skill), do: ~c"#{skill.name}"
  end
end
