defmodule Vutuv.Profiles.Address do
  @moduledoc false

  use VutuvWeb, :model

  schema "addresses" do
    field(:description, :string)
    field(:line_1, :string)
    field(:line_2, :string)
    field(:line_3, :string)
    field(:line_4, :string)
    field(:zip_code, :string)
    field(:city, :string)
    field(:state, :string)
    field(:country, :string)
    # The owner's chosen display order. Set programmatically (on create and via
    # the reorder/move actions), never cast from user params. NULLs sort last so
    # legacy rows fall back to creation order until reordered. See Vutuv.Ordering.
    field(:position, :integer)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  @doc "Addresses in the owner's chosen order (see `Vutuv.Ordering`)."
  def ordered(query \\ __MODULE__), do: Vutuv.Ordering.by_position(query)

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned
  with no validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [
      :description,
      :line_1,
      :line_2,
      :line_3,
      :line_4,
      :zip_code,
      :city,
      :state,
      :country
    ])
    |> validate_required([:description, :country])
    |> validate_length(:description, max: 100)
    |> validate_length(:line_1, max: 255)
    |> validate_length(:line_2, max: 255)
    |> validate_length(:line_3, max: 255)
    |> validate_length(:line_4, max: 255)
    |> validate_length(:zip_code, max: 32)
    |> validate_length(:city, max: 100)
    |> validate_length(:state, max: 100)
    |> validate_length(:country, max: 100)
  end
end
