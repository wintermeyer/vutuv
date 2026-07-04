defmodule Vutuv.Search.SearchQuery do
  @moduledoc false

  use VutuvWeb, :model
  import Vutuv.ChangesetHelpers, only: [downcase_value: 1]
  @derive {Phoenix.Param, key: :value}

  schema "search_queries" do
    field(:value, :string)
    field(:email?, :boolean)

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
    |> cast(params, [:value, :email?])
    |> validate_required([:value, :email?])
    # varchar(255) column fed from raw ?q= URL input: an oversized query must
    # be a skipped changeset error, never a raised Postgres 22001 that would
    # crash-loop SearchLive on every re-mount from the same URL.
    |> validate_length(:value, max: 255)
    |> cast_assoc(:search_query_results)
    |> cast_assoc(:search_query_requesters)
    |> unique_constraint(:value)
    |> downcase_value
  end
end
