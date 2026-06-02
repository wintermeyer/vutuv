defmodule Vutuv.Recruiting.Coupon do
  @moduledoc false

  use VutuvWeb, :model

  schema "coupons" do
    field(:code, :string)
    field(:amount, :decimal)
    field(:percentage, :integer)
    field(:ends_on, :date)
    field(:valid, :boolean, default: true)

    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:recruiter_package, Vutuv.Recruiting.RecruiterPackage)

    timestamps()
  end

  @doc """
  Builds a changeset based on the `struct` and `params`.
  """
  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [
      :code,
      :user_id,
      :recruiter_package_id,
      :amount,
      :percentage,
      :ends_on,
      :valid
    ])
    |> validate_required([:code, :ends_on])
    |> validate_length(:code, is: 8)
    |> validate_format(:code, ~r/[A-Z0-9]{8}/)
    |> validate_inclusion(:percentage, Enum.to_list(1..100) ++ [nil])
    |> validate_current_or_future_date(:ends_on)
    |> validate_presence_of_amount_or_percentage(params)
    |> unique_constraint(:code)
  end

  def random_code do
    bytes = "ACDEFGHKLMNPRSTUVWXY234569"

    for(_ <- 1..8, do: :binary.at(bytes, :rand.uniform(byte_size(bytes)) - 1))
    |> List.to_string()
  end

  defp validate_current_or_future_date(%{changes: changes} = changeset, field) do
    if date = changes[field] do
      do_validate_current_or_future_date(changeset, field, date)
    else
      changeset
    end
  end

  defp do_validate_current_or_future_date(changeset, field, date) do
    today = Date.utc_today()

    if Date.compare(date, today) == :lt do
      changeset
      |> add_error(field, "Date in the past")
    else
      changeset
    end
  end

  defp validate_presence_of_amount_or_percentage(changeset, %{}) do
    amount = get_field(changeset, :amount)
    percentage = get_field(changeset, :percentage)

    if amount || percentage do
      if amount && percentage do
        message = "Amount or percentage must be present. Not both."

        changeset
        |> add_error(:amount, message)
        |> add_error(:percentage, message)
      else
        changeset
      end
    else
      message = "Amount or percentage must be present"

      changeset
      |> add_error(:amount, message)
      |> add_error(:percentage, message)
    end
  end
end
