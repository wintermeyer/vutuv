defmodule Vutuv.Soundex do
  @moduledoc false

  @doc """
  Soundex is an implementation of the SoundEX algorithm, designed to encode names of into a phonetic code representing
  the pronunciation of the name. For more information on the rules of the algorithm, visit the following wikipedia page: https://en.wikipedia.org/wiki/Soundex
  """

  # List of replacements for function generation
  replaces =
    [
      {?b, ~c"1"},
      {?f, ~c"1"},
      {?p, ~c"1"},
      {?v, ~c"1"},
      {?c, ~c"2"},
      {?g, ~c"2"},
      {?j, ~c"2"},
      {?k, ~c"2"},
      {?q, ~c"2"},
      {?s, ~c"2"},
      {?x, ~c"2"},
      {?z, ~c"2"},
      {?d, ~c"3"},
      {?t, ~c"3"},
      {?l, ~c"4"},
      {?m, ~c"5"},
      {?n, ~c"5"},
      {?r, ~c"6"}
    ]

  # List of breaking drops for function generation
  breaking_drops =
    [
      ?a,
      ?e,
      ?i,
      ?o,
      ?u,
      ?y
    ]

  # List of non-breaking drops for function generation
  drops =
    [
      ?h,
      ?w
    ]

  # Same bound and same reason as `Vutuv.ColognePhonetics`: a name, handed over
  # by a stranger from the public search box or from raw sign-up params.
  @max_chars 100

  def to_soundex(""), do: ""

  def to_soundex(nil), do: nil

  def to_soundex(string) do
    # Downcase to prevent unwanted behavior
    string
    |> String.byte_slice(0, @max_chars * 4)
    |> String.slice(0, @max_chars)
    |> String.downcase()
    # Normalizes special characters
    |> normalize
    # Converts the string into a char list
    |> to_charlist
    # Converts the string to representative coded numbers in a char list
    |> encode
    # Converts the encoded char list back to a string
    |> to_string
    # Capitalizes the first letter
    |> String.capitalize()
    # Appends zeroes to the end of the string until it's length is 4
    |> String.pad_trailing(4, "0")
    |> String.split_at(4)
    # Trims the string if the length is > 4
    |> elem(0)
  end

  defp encode(~c""), do: ~c""

  defp encode([head | tail]) do
    new_tail =
      tail
      |> Enum.filter(&first_drop/1)
      |> encode_list(~c"", head)
      # Removes consecutive duplicates
      |> Enum.dedup()
      |> tl
      |> Enum.filter(&second_drop/1)

    [head | new_tail]
  end

  defp encode_list(tail, ~c"", head), do: encode_list([head | tail], ~c"")

  # The accumulator collects the replacements in reverse and is turned around
  # once at the end. Appending per character (`encoded ++ [replace(head)]`)
  # copies the whole accumulator every time, which is quadratic in the length of
  # the word — and the word comes from the public `/search` box (see the work
  # bound in `test/vutuv/soundex_test.exs`).
  defp encode_list(~c"", encoded), do: Enum.reverse(encoded)

  # Recurses the char list and applies the apropriate replacements until it has replaced each letter
  defp encode_list([head | tail], encoded) do
    encode_list(tail, [replace(head) | encoded])
  end

  # Generates non-breaking drops
  for char <- drops do
    defp first_drop(unquote(char)), do: false
  end

  defp first_drop(_), do: true

  # Generates replacements
  for {char, code} <- replaces do
    defp replace(unquote(char)), do: unquote(code)
  end

  defp replace(char), do: char

  # Generates breaking drops
  for char <- breaking_drops do
    defp second_drop(unquote(char)), do: false
  end

  defp second_drop(_), do: true

  defp normalize(string), do: Vutuv.ChangesetHelpers.normalize_name(string)
end
