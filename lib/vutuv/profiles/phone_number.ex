defmodule Vutuv.Profiles.PhoneNumber do
  @moduledoc false

  use VutuvWeb, :model

  schema "phone_numbers" do
    field(:value, :string)
    field(:number_type, :string)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  @format_message ~s/Please enter a valid phone number/
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
    |> normalize_value()
  end

  # Rewrites a typed number to canonical international format (`0261-123456` ->
  # `+49 261 123456`) and rejects anything that is not a real phone number, so
  # only validated, normalized values reach the database. See
  # `Vutuv.Phone.normalize/1`.
  defp normalize_value(changeset) do
    case get_change(changeset, :value) do
      value when is_binary(value) ->
        case Vutuv.Phone.normalize(value) do
          {:ok, normalized} -> put_change(changeset, :value, normalized)
          :error -> add_error(changeset, :value, @format_message)
        end

      _ ->
        changeset
    end
  end
end
