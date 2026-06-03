defmodule Vutuv.Accounts.LoginPin do
  @moduledoc false

  use VutuvWeb, :model

  schema "login_pins" do
    field(:value, :string)
    field(:type, :string)
    field(:created_at, :naive_datetime)
    # `pin` stores the peppered, salted HMAC of the PIN (hex), never plaintext.
    field(:pin, :string)
    field(:pin_salt, :binary)
    field(:pin_login_attempts, :integer, default: 0)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [
      :value,
      :type,
      :created_at,
      :pin,
      :pin_salt,
      :pin_login_attempts
    ])
    |> unique_constraint(:user_id,
      name: :login_pins_user_id_type_index,
      message: "already has a login pin of this type"
    )
  end
end
