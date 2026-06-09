defmodule Vutuv.Search do
  @moduledoc false

  import Ecto.Query
  alias Vutuv.Accounts.SearchTerm
  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.Search.SearchQueryResult

  # Checks database for matches between search.value and search_terms
  def search(value, false) do
    value = String.downcase(value)
    cologne_fuzzy_value = phoneticize_search_value(value, :cologne)
    soundex_fuzzy_value = phoneticize_search_value(value, :soundex)

    for(
      term <-
        Repo.all(
          from(t in SearchTerm,
            left_join: u in assoc(t, :user),
            where:
              (is_nil(u.activated?) or u.activated? == true) and
                (like(t.value, ^"#{value}%") or ^cologne_fuzzy_value == t.value or
                   ^soundex_fuzzy_value == t.value)
          )
        )
    ) do
      %{
        score: term.score,
        result: %SearchQueryResult{
          user_id: term.user_id
        }
      }
    end
    # Sorts by score
    |> Enum.sort(&(&1.score > &2.score))
    # Filters duplicates
    |> Enum.uniq_by(& &1.result)
    # Maps to flat list of users
    |> Enum.map(& &1.result)
  end

  # Searches for user that matches email
  def search(value, true) do
    value = String.downcase(value)

    Repo.all(
      from(u in User,
        join: e in assoc(u, :emails),
        where: (is_nil(u.activated?) or u.activated? == true) and ^value == e.value
      )
    )
    # Filters duplicates
    |> Enum.uniq_by(& &1.id)
  end

  defp phoneticize_search_value(value, algorithm) do
    # Split the value by non words
    for(section <- Regex.split(~r/[^a-z]+/, value, include_captures: true)) do
      phoneticize_section(section, algorithm)
    end
    # Recombine the search value with phoneticized words
    |> Enum.join()
  end

  defp phoneticize_section(section, algorithm) do
    if Regex.match?(~r/^[a-z]+$/, section) do
      # Phoneticize the words based on the algorithm parameter
      case algorithm do
        :cologne -> Vutuv.ColognePhonetics.to_cologne(section)
        :soundex -> Vutuv.Soundex.to_soundex(section)
      end
    else
      # Retain the non-words
      section
    end
  end
end
