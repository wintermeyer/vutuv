defmodule Vutuv.References.SkillVersion do
  @moduledoc """
  One fetched body of the Arbeitszeugnis analysis prompt.

  Rows accumulate rather than being replaced: a `reference_checks` row names
  the `skill_sha256` that produced it, and a result nobody can trace back to a
  prompt is a result nobody can defend. Written only by
  `Vutuv.References.Skill`, so there is no user-facing changeset.
  """

  use VutuvWeb, :model

  @sources ~w(remote vendored)

  schema "reference_skill_versions" do
    field(:version, :string)
    field(:sha256, :string)
    field(:body, :string)
    field(:source, :string)
    field(:fetched_at, :utc_datetime)

    timestamps()
  end

  @doc "The known provenances of a body."
  def sources, do: @sources

  @doc false
  def changeset(model, params) do
    model
    |> cast(params, ~w(version sha256 body source fetched_at)a)
    |> validate_required(~w(sha256 body source fetched_at)a)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:version, max: 255)
    |> validate_length(:sha256, max: 255)
    |> unique_constraint(:sha256)
  end
end
