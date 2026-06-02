defmodule Vutuv.Profiles.SkillTest do
  use Vutuv.ModelCase

  alias Vutuv.Profiles.Skill

  @valid_attrs %{"name" => "skill_name"}
  @invalid_attrs %{}

  test "changeset with valid attributes" do
    changeset = Skill.changeset(%Skill{}, @valid_attrs)
    assert changeset.valid?
  end

  test "changeset with invalid attributes" do
    changeset = Skill.changeset(%Skill{}, @invalid_attrs)
    refute changeset.valid?
  end
end
