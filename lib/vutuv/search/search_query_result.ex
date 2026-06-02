defmodule Vutuv.Search.SearchQueryResult do
  @moduledoc false

  use VutuvWeb, :model

  schema "search_query_results" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:search_query, Vutuv.Search.SearchQuery)
    timestamps()
  end

  @doc """
  Creates a changeset based on the `model` and `params`.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [])
  end
end
