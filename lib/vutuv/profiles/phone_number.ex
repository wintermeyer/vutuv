defmodule Vutuv.Profiles.PhoneNumber do
  @moduledoc false

  use VutuvWeb, :model

  schema "phone_numbers" do
    field(:value, :string)
    field(:number_type, :string)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  @format_message ~s/Please enter a phone number/
  @requred_message ~s/This field is required/

  # The allowed `number_type` labels, in the order the HTML form lists them.
  # Mirrors Email.email_types: enforced in the schema, not just the <select>.
  @number_types ~w(Work Cell Home Fax)

  @doc "The allowed `number_type` values, in the order the forms list them."
  def number_types, do: @number_types

  @doc """
  Creates a changeset based on the `model` and `params`.

  If no params are provided, an invalid changeset is returned
  with no validation performed.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [:value, :number_type])
    |> validate_required([:value, :number_type], message: @requred_message)
    |> validate_inclusion(:number_type, @number_types)
    |> update_change(:value, &String.trim/1)
    # |> update_change(:value, &String.replace(&1,~r/[^+0-9]/, ""))
    |> validate_format(:value, ~r/^\S[+\d\(\)\s-]*\S$/u, message: @format_message)
  end
end
