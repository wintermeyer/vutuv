defmodule Vutuv.Accounts.Exonym do
  @moduledoc false

  use VutuvWeb, :model

  schema "exonyms" do
    field(:value, :string)

    belongs_to(:locale, Vutuv.Accounts.Locale)

    belongs_to(:exonym_locale, Vutuv.Accounts.Locale)

    timestamps()
  end

  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [:value, :locale_id, :exonym_locale_id])
    |> validate_required([:value, :locale_id, :exonym_locale_id])
    |> foreign_key_constraint(:locale)
    |> foreign_key_constraint(:exonym_locale)
    |> unique_constraint(:value_locale_id)
    |> validate_length(:value, max: 40)
  end
end
