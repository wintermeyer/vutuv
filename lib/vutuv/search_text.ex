defmodule Vutuv.SearchText do
  @moduledoc """
  Text helpers shared by the `LIKE`/`ILIKE` search queries in the
  `Vutuv.Posts`, `Vutuv.Social` and `Vutuv.Search` contexts.

  Kept in one place so the wildcard-escaping rule (a security-relevant string
  escape), the query-length cap and the blank-to-nil normalization each have a
  single definition instead of a copy per context.
  """

  # The longest search string a query box accepts. Nobody searches for a name,
  # tag or city this long, and several of these boxes are open to visitors
  # (`/search`, the member directory at `/system/members`, the job board), where
  # an uncapped value becomes a megabyte `ILIKE '%…%'` pattern, a megabyte
  # `websearch_to_tsquery`, and a megabyte handed to the phonetic encoders.
  @max_chars 200

  @doc "The longest search string `cap/1` and `normalize_search/1` let through."
  def max_chars, do: @max_chars

  @doc """
  Cuts a search string to `max_chars/0`.

  Bytes first, graphemes second: `String.slice/3` alone walks the *whole* input
  to find its cut point (131_093 reductions on a megabyte, against 961 for the
  entire `Vutuv.Search.parse/2` it protects), so the byte cut bounds the work
  first and the grapheme cut then lands on a character boundary. Four bytes per
  grapheme is UTF-8's ceiling, so nothing under the cap is ever shortened.
  """
  def cap(value) when is_binary(value) do
    value |> String.byte_slice(0, @max_chars * 4) |> String.slice(0, @max_chars)
  end

  def cap(value), do: value

  @doc """
  Trims a search string, collapsing a blank (or non-binary) value to `nil` so a
  caller can pattern-match "no search" in one spot.

  Deliberately does **not** cap: despite the name this is the tree's general
  "trim, blank to nil" normalizer, and `Vutuv.Fediverse` runs remote URIs
  (`object["id"]`, `object["url"]`, `quoteAuthorization`) and `Vutuv.Moderation`
  a report reason through it. Capping here silently shortened a 2 KB quote URI
  to 200 characters and slipped it past the length check that was supposed to
  drop it. Search entry points call `cap/1` themselves.
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
  The LIKE "contains" pattern for `term`: the escaped term wrapped in `%…%`,
  ready for `ilike`/`like`.
  """
  def contains(term), do: "%" <> escape_like(term) <> "%"

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
