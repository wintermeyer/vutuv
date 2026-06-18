defmodule Vutuv.SearchText do
  @moduledoc """
  Text helpers shared by the `LIKE`/`ILIKE` search queries in the
  `Vutuv.Posts`, `Vutuv.Social` and `Vutuv.Search` contexts.

  Kept in one place so the wildcard-escaping rule (a security-relevant string
  escape) and the blank-to-nil normalization each have a single definition
  instead of a copy per context.
  """

  @doc """
  Trims a search string, collapsing a blank (or non-binary) value to `nil` so a
  caller can pattern-match "no search" in one spot.
  """
  def normalize_search(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      term -> term
    end
  end

  def normalize_search(_), do: nil

  @doc """
  Escapes the `LIKE`/`ILIKE` wildcards (`\\`, `%`, `_`) in `term` so a typed
  wildcard matches literally instead of acting as a pattern metacharacter.
  """
  def escape_like(term), do: String.replace(term, ~r/[\\%_]/, &("\\" <> &1))
end
