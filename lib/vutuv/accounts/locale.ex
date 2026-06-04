defmodule Vutuv.Accounts.Locale do
  @moduledoc false

  use VutuvWeb, :model
  import Ecto.Query

  schema "locales" do
    field(:value, :string)
    field(:endonym, :string)

    has_many(:exonyms, Vutuv.Accounts.Exonym)

    timestamps()
  end

  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [:value, :endonym])
    |> validate_required([:value, :endonym])
    |> unique_constraint(:value)
  end

  def locale_select_list do
    list = Vutuv.Repo.all(from(l in __MODULE__, select: {l.endonym, l.id}, order_by: l.endonym))

    for({endonym, id} <- list) do
      {String.capitalize(endonym), id}
    end
  end

  defimpl String.Chars, for: Vutuv.Accounts.Locale do
    def to_string(locale), do: String.upcase("#{locale.value}")
  end

  defimpl List.Chars, for: Vutuv.Accounts.Locale do
    def to_charlist(locale), do: ~c"#{locale.value}"
  end
end
