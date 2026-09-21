defmodule Vutuv.SearchHelpers do
  @moduledoc false

  import Vutuv.Factory

  alias Vutuv.Accounts.SearchTerm
  alias Vutuv.Repo

  @doc """
  A member findable by name search. The factory does not create search terms
  (`Accounts.create_user/1` does), so this inserts the same terms it would.
  """
  def searchable_user(first, last, attrs \\ []) do
    user = insert(:activated_user, Keyword.merge([first_name: first, last_name: last], attrs))

    for changeset <-
          SearchTerm.create_search_terms(%{"first_name" => first, "last_name" => last}) do
      changeset |> Ecto.Changeset.put_change(:user_id, user.id) |> Repo.insert!()
    end

    user
  end
end
