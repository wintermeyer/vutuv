defmodule Vutuv.ColognePhonetics do
  @moduledoc false

  @doc """
  ColognePhonetics is an implementation of the Cologne Phonetics algorithm, designed to encode names of Germanic origin into a phonetic code representing
  the pronunciation of the name. For more information on the rules of the algorithm, visit the following wikipedia page: https://en.wikipedia.org/wiki/Cologne_phonetics
  """

  cologne_replacements_with_rules =
    [
      # This is the replacement list with rules included. The order is very important
      # for the correct functionality of the algorithm. This is because the match
      # functions generate in the same order as the rules are defined.
      {?p, ~c"3", %{before: ?h}},
      {?c, ~c"4", %{first: true, before: ?a}},
      {?c, ~c"4", %{first: true, before: ?h}},
      {?c, ~c"4", %{first: true, before: ?k}},
      {?c, ~c"4", %{first: true, before: ?l}},
      {?c, ~c"4", %{first: true, before: ?o}},
      {?c, ~c"4", %{first: true, before: ?q}},
      {?c, ~c"4", %{first: true, before: ?r}},
      {?c, ~c"4", %{first: true, before: ?u}},
      {?c, ~c"4", %{first: true, before: ?x}},
      {?c, ~c"8", %{after: ?s}},
      {?c, ~c"8", %{after: ?z}},
      {?c, ~c"8", %{first: true}},
      {?c, ~c"4", %{before: ?a}},
      {?c, ~c"4", %{before: ?h}},
      {?c, ~c"4", %{before: ?k}},
      {?c, ~c"4", %{before: ?o}},
      {?c, ~c"4", %{before: ?q}},
      {?c, ~c"4", %{before: ?u}},
      {?c, ~c"4", %{before: ?x}},
      {?d, ~c"8", %{before: ?c}},
      {?d, ~c"8", %{before: ?s}},
      {?d, ~c"8", %{before: ?z}},
      {?t, ~c"8", %{before: ?c}},
      {?t, ~c"8", %{before: ?s}},
      {?t, ~c"8", %{before: ?z}},
      {?x, ~c"8", %{after: ?c}},
      {?x, ~c"8", %{after: ?k}},
      {?x, ~c"8", %{after: ?q}}
    ]

  cologne_replacements =
    [
      # This is the list for basic replacements. Order does not matter here.
      {?a, ~c"0"},
      {?e, ~c"0"},
      {?i, ~c"0"},
      {?j, ~c"0"},
      {?o, ~c"0"},
      {?u, ~c"0"},
      {?y, ~c"0"},
      {?h, ~c""},
      {?b, ~c"1"},
      {?p, ~c"1"},
      {?d, ~c"2"},
      {?t, ~c"2"},
      {?f, ~c"3"},
      {?v, ~c"3"},
      {?w, ~c"3"},
      {?g, ~c"4"},
      {?k, ~c"4"},
      {?q, ~c"4"},
      {?x, ~c"48"},
      {?l, ~c"5"},
      {?m, ~c"6"},
      {?n, ~c"6"},
      {?r, ~c"7"},
      {?s, ~c"8"},
      {?z, ~c"8"},
      {?c, ~c"8"}
    ]

  def to_cologne(""), do: ""

  def to_cologne(nil), do: nil

  # The three steps of the cologne phonetics algorithm.
  def to_cologne(string) do
    # Downcase to prevent unwanted behavior
    String.downcase(string)
    # Normalizes special characters
    |> normalize
    # Converts the string to representative coded numbers in a char list
    |> encode_string
    # Removes consecutive duplicates
    |> Enum.dedup()
    # Removes all zeroes, ignoring the first character
    |> remove_zeroes
    # Converts char_list to string for return
    |> to_string
  end

  defp encode_string(""), do: ~c""

  defp encode_string(string) do
    [head | tail] = String.to_charlist(string)
    # Initiate recursion
    encode_string(~c"", nil, nil, head, tail)
  end

  defp encode_string(encoded, prev, char, next, [head | tail]) do
    # As long as the char list is not empty, recurse
    (encoded ++ encode(prev, char, next))
    |> encode_string(char, next, head, tail)
  end

  defp encode_string(encoded, prev, char, next, []) do
    # If the char list is empty, the operation  is finished, encode the last two letters.
    encoded ++
      encode(prev, char, next) ++
      encode(char, next, nil)
  end

  # This function block defines pattern matchable functions for every possible replacement.
  # This allows for ultra fast processing of the replacements.

  # This generates special rule matches
  for {char, code, rule} <- cologne_replacements_with_rules do
    cond do
      rule[:before] && rule[:after] ->
        defp encode(unquote(rule.after), unquote(char), unquote(rule.before)), do: unquote(code)

      rule[:first] && rule[:before] ->
        defp encode(nil, unquote(char), unquote(rule.before)), do: unquote(code)

      rule[:first] ->
        defp encode(nil, unquote(char), _), do: unquote(code)

      rule[:before] ->
        defp encode(_, unquote(char), unquote(rule.before)), do: unquote(code)

      rule[:after] ->
        defp encode(unquote(rule.after), unquote(char), _), do: unquote(code)
    end
  end

  # This generates simple matches
  for {char, code} <- cologne_replacements do
    defp encode(_, unquote(char), _), do: unquote(code)
  end

  # If the recursion is just starting, the selected character will be nil, so don't add to the encoded string.
  defp encode(_, nil, _), do: ~c""

  # This prevents the algorithm from failing due to unexpected characters.
  defp encode(_, _, _), do: ~c""

  defp remove_zeroes([head | tail]) do
    [head | Enum.reject(tail, &(&1 == ?0))]
  end

  defp remove_zeroes(string), do: string

  defp normalize(string), do: Vutuv.ChangesetHelpers.normalize_name(string)
end
