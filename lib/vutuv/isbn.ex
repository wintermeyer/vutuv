defmodule Vutuv.Isbn do
  @moduledoc """
  ISBN parsing for the post review card (`Vutuv.Posts.PostReview`).

  `normalize/1` accepts what people actually paste — ISBN-10 or ISBN-13, with
  hyphens, spaces or a leading "ISBN" label — validates the check digit and
  returns the canonical bare ISBN-13, the one form stored and used for the
  Open Library cover/metadata lookups. `isbn10/1` derives the ISBN-10 twin of
  a 978-prefixed ISBN-13 (the identifier Amazon's `/dp/` URLs take); 979
  ISBNs have no ISBN-10 form by definition. `format/1` turns the stored bare
  digits back into the hyphenated form a reader expects to see.

  Where an ISBN splits is not computable — the registration group and the
  registrant are assigned ranges — so `format/1` reads them from
  `priv/isbn_ranges.txt`, the International ISBN Agency's RangeMessage boiled
  down to one rule per line and compiled into this module. The table only ever
  goes stale downwards: a registrant range assigned after the last refresh is
  simply unknown, and the ISBN renders unhyphenated instead of wrongly split.
  Refresh it with `mix run scripts/update_isbn_ranges.exs`.
  """

  @external_resource ranges_path = Path.join([__DIR__, "..", "..", "priv", "isbn_ranges.txt"])

  @ranges ranges_path
          |> File.stream!()
          |> Stream.map(&String.trim/1)
          |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
          |> Stream.map(&String.split(&1, " "))
          |> Enum.group_by(fn [prefix | _rule] -> prefix end, fn [_prefix, low, high, length] ->
            {String.to_integer(low), String.to_integer(high), String.to_integer(length)}
          end)

  @doc """
  Canonicalizes `input` into a bare, checksum-valid ISBN-13 string —
  `{:ok, "9783161484100"}` — or `:error`. An ISBN-10 is converted to its
  978-prefixed ISBN-13 equivalent.
  """
  def normalize(input) when is_binary(input) do
    case strip(input) do
      <<_::binary-size(13)>> = digits -> normalize13(digits)
      <<_::binary-size(10)>> = digits -> normalize10(digits)
      _other -> :error
    end
  end

  def normalize(_input), do: :error

  @doc """
  The ISBN-10 form of a normalized ISBN-13, for building an Amazon `/dp/`
  link — `{:ok, "316148410X"}` — or `:error` (979 ISBNs, invalid input).
  """
  def isbn10(<<"978", body::binary-size(9), _check::binary-size(1)>> = isbn13) do
    with {:ok, ^isbn13} <- normalize13(isbn13) do
      {:ok, body <> check10(body)}
    end
  end

  def isbn10(_other), do: :error

  @doc """
  The printed form of a stored ISBN-13 — `"9783442541683"` becomes
  `"978-3-442-54168-3"`: EAN prefix, registration group, registrant,
  publication element, check digit.

  Anything the ranges don't resolve (an unassigned or freshly assigned
  registrant range, an already hyphenated string, a non-ISBN, `nil`) comes
  back unchanged, so callers can render the result without a fallback branch.
  """
  def format(isbn) when is_binary(isbn) do
    case hyphenate(isbn) do
      {:ok, formatted} -> formatted
      :error -> isbn
    end
  end

  def format(isbn), do: isbn

  defp hyphenate(<<prefix::binary-size(3), body::binary-size(9), check::binary-size(1)>> = isbn) do
    digits = body <> check

    with true <- isbn =~ ~r/^\d{13}$/,
         {:ok, group} <- element(prefix, digits),
         rest = drop(digits, group),
         {:ok, registrant} <- element(prefix <> "-" <> group, rest),
         # What is left after the registrant is the publication element plus
         # the check digit; an ISBN whose registrant swallows all of it is not
         # a real one, so leave it alone rather than emit an empty segment.
         publication =
           binary_part(rest, byte_size(registrant), publication_size(rest, registrant)),
         true <- publication != "" do
      {:ok, Enum.join([prefix, group, registrant, publication, check], "-")}
    else
      _other -> :error
    end
  end

  defp hyphenate(_other), do: :error

  # The leading digits of `digits` that the rules of `prefix` mark as one
  # element: the registration group under an EAN prefix ("978"), the
  # registrant under a group ("978-3"). Rules are keyed on the seven digits
  # following the prefix, zero-padded when fewer are left; length 0 marks an
  # unassigned range.
  defp element(prefix, digits) do
    value = digits |> String.slice(0, 7) |> String.pad_trailing(7, "0") |> String.to_integer()

    @ranges
    |> Map.get(prefix, [])
    |> Enum.find(fn {low, high, _length} -> value >= low and value <= high end)
    |> case do
      {_low, _high, length} when length > 0 and length < byte_size(digits) ->
        {:ok, binary_part(digits, 0, length)}

      _other ->
        :error
    end
  end

  defp drop(digits, element),
    do: binary_part(digits, byte_size(element), byte_size(digits) - byte_size(element))

  defp publication_size(rest, registrant), do: byte_size(rest) - byte_size(registrant) - 1

  # Uppercases (the ISBN-10 X), drops separators and an optional leading
  # "ISBN"/"ISBN:" label.
  defp strip(input) do
    input
    |> String.trim()
    |> String.upcase()
    |> String.replace_prefix("ISBN", "")
    |> String.replace(~r/[\s:-]/, "")
  end

  defp normalize13(digits) do
    if digits =~ ~r/^\d{13}$/ and valid13?(digits), do: {:ok, digits}, else: :error
  end

  defp normalize10(digits) do
    if digits =~ ~r/^\d{9}[\dX]$/ and valid10?(digits) do
      body = "978" <> binary_part(digits, 0, 9)
      {:ok, body <> check13(body)}
    else
      :error
    end
  end

  # ISBN-13: digits weighted 1,3,1,3,… must sum to a multiple of 10.
  defp valid13?(digits) do
    digits
    |> digit_values()
    |> Enum.with_index()
    |> Enum.reduce(0, fn {value, index}, sum ->
      sum + value * if(rem(index, 2) == 0, do: 1, else: 3)
    end)
    |> rem(10) == 0
  end

  # ISBN-10: digits weighted 10..1 (X = 10) must sum to a multiple of 11.
  defp valid10?(digits) do
    digits
    |> digit_values()
    |> Enum.with_index()
    |> Enum.reduce(0, fn {value, index}, sum -> sum + value * (10 - index) end)
    |> rem(11) == 0
  end

  defp check13(body) do
    sum =
      body
      |> digit_values()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {value, index}, sum ->
        sum + value * if(rem(index, 2) == 0, do: 1, else: 3)
      end)

    Integer.to_string(rem(10 - rem(sum, 10), 10))
  end

  defp check10(body) do
    sum =
      body
      |> digit_values()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {value, index}, sum -> sum + value * (10 - index) end)

    case rem(11 - rem(sum, 11), 11) do
      10 -> "X"
      digit -> Integer.to_string(digit)
    end
  end

  defp digit_values(digits) do
    for <<char <- digits>>, do: if(char == ?X, do: 10, else: char - ?0)
  end
end
