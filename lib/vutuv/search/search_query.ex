defmodule Vutuv.Search.SearchQuery do
  @moduledoc false

  use VutuvWeb, :model
  @derive {Phoenix.Param, key: :value}

  schema "search_queries" do
    field(:value, :string)
    field(:is_email?, :boolean)

    has_many(:search_query_results, Vutuv.Search.SearchQueryResult, on_replace: :delete)
    has_many(:search_query_requesters, Vutuv.Search.SearchQueryRequester)

    has_many(:user_results, through: [:search_query_results, :user])
    timestamps()
  end

  @doc """
  Creates a changeset based on the `model` and `params`.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [:value, :is_email?])
    |> validate_required([:value, :is_email?])
    |> cast_assoc(:search_query_results)
    |> cast_assoc(:search_query_requesters)
    |> unique_constraint(:value)
    |> downcase_value
  end

  defp downcase_value(changeset), do: Vutuv.ChangesetHelpers.downcase_value(changeset)
end
