defmodule Vutuv.PeopleHistory.Snapshot do
  @moduledoc """
  One German calendar day's head count: the members of this installation and
  the Fediverse accounts following something on it, the same pair
  `Vutuv.PeopleCounter` publishes live.

  `day` is unique, so a re-run of the recorder updates the day it already wrote
  instead of drawing the curve twice.
  """

  use VutuvWeb, :model

  schema "people_snapshots" do
    field(:day, :date)
    field(:members, :integer)
    field(:fediverse_accounts, :integer)

    timestamps()
  end

  @doc """
  The day's people total, the figure the top bar shows: both halves added up.
  Here rather than at each reader, so the curve and `PeopleHistory.growth/1`
  cannot disagree about what "people" means.
  """
  def total(%__MODULE__{members: members, fediverse_accounts: fediverse}),
    do: members + fediverse

  def changeset(%__MODULE__{} = snapshot, attrs) do
    snapshot
    |> cast(attrs, [:day, :members, :fediverse_accounts])
    |> validate_required([:day, :members, :fediverse_accounts])
    |> validate_number(:members, greater_than_or_equal_to: 0)
    |> validate_number(:fediverse_accounts, greater_than_or_equal_to: 0)
    |> unique_constraint(:day)
  end
end
