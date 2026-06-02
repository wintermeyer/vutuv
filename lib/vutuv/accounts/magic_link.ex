defmodule Vutuv.Accounts.MagicLink do
  @moduledoc false

  use VutuvWeb, :model

  schema "magic_links" do
    field(:value, :string)
    field(:magic_link, :string)
    field(:magic_link_type, :string)
    field(:magic_link_created_at, :naive_datetime)
    field(:pin, :string)
    field(:pin_login_attempts, :integer, default: 0)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [
      :value,
      :magic_link,
      :magic_link_created_at,
      :magic_link_type,
      :pin,
      :pin_login_attempts
    ])
    |> unique_constraint(:user_id,
      name: :magic_links_user_id_magic_link_type_index,
      message: "already has a magic link of this type"
    )
  end
end
