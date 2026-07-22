defmodule Vutuv.Isbn do
  @moduledoc """
  ISBN parsing for the post review card (`Vutuv.Posts.PostReview`).

  `normalize/1` accepts what people actually paste — ISBN-10 or ISBN-13, with
  hyphens, spaces or a leading "ISBN" label — validates the check digit and
  returns the canonical bare ISBN-13, the one form stored and used for the
  Open Library cover/metadata lookups. `isbn10/1` derives the ISBN-10 twin of
  a 978-prefixed ISBN-13 (the identifier Amazon's `/dp/` URLs take); 979
  ISBNs have no ISBN-10 form by definition.
  """

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
