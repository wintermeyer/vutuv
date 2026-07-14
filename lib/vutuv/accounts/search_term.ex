defmodule Vutuv.Accounts.SearchTerm do
  @moduledoc false

  use VutuvWeb, :model
  import Vutuv.ChangesetHelpers, only: [downcase_value: 1]

  schema "search_terms" do
    field(:value, :string)
    field(:score, :integer)

    belongs_to(:user, Vutuv.Accounts.User)
    timestamps()
  end

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [:value, :score])
    |> downcase_value
  end

  def create_search_terms(%{"first_name" => first_name, "last_name" => last_name}) do
    terms = combine_terms(first_name, last_name)

    fuzzy_terms =
      combine_terms(
        Vutuv.ColognePhonetics.to_cologne(first_name),
        Vutuv.ColognePhonetics.to_cologne(last_name)
      ) ++
        combine_terms(Vutuv.Soundex.to_soundex(first_name), Vutuv.Soundex.to_soundex(last_name))

    for(term <- terms) do
      changeset(%Vutuv.Accounts.SearchTerm{}, %{value: term, score: 100})
    end ++
      for(term <- fuzzy_terms) do
        changeset(%Vutuv.Accounts.SearchTerm{}, %{value: term, score: 80})
      end
  end

  def create_search_terms(_), do: []

  defp combine_terms(first_name, last_name) do
    [
      first_name,
      last_name,
      "#{first_name} #{last_name}",
      "#{last_name} #{first_name}",
      "#{first_name}, #{last_name}",
      "#{last_name}, #{first_name}"
    ]
  end
end
