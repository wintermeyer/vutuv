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

  @doc """
  Query macro: case-insensitive name match on `first`, `last`, or the
  "first last" concatenation, against `pattern`. Compose it with `or` and a
  site's own extra columns inside a `where`. The bound columns are passed
  explicitly (`name_ilike(t.first_name, t.last_name, ^pattern)`) because the
  query binding name differs per call site (`target`, `author`, plain user).
  """
  defmacro name_ilike(first, last, pattern) do
    quote do
      ilike(unquote(first), unquote(pattern)) or ilike(unquote(last), unquote(pattern)) or
        ilike(fragment("? || ' ' || ?", unquote(first), unquote(last)), unquote(pattern))
    end
  end
end
