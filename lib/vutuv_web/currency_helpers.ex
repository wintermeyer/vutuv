defmodule VutuvWeb.CurrencyHelpers do
  @moduledoc false

  @doc """
  Formats a number as currency string.
  Replacement for Number.Currency.number_to_currency/2.
  """
  def number_to_currency(number, opts \\ [])
  def number_to_currency(nil, _opts), do: ""

  def number_to_currency(number, opts) do
    precision = Keyword.get(opts, :precision, 2)
    delimiter = Keyword.get(opts, :delimiter, ",")
    unit = Keyword.get(opts, :unit, "$")

    formatted =
      number
      |> Kernel./(1)
      |> :erlang.float_to_binary(decimals: precision)

    [integer_part | decimal_parts] = String.split(formatted, ".")

    # Split the leading sign off before grouping so the "-" is not treated as a
    # digit (which would yield a stray delimiter, e.g. "$-,999.00").
    {sign, digits} =
      case integer_part do
        "-" <> rest -> {"-", rest}
        rest -> {"", rest}
      end

    grouped_digits =
      digits
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.map(&Enum.reverse/1)
      |> Enum.reverse()
      |> Enum.map_join(delimiter, &Enum.join/1)

    integer_with_delimiter = sign <> grouped_digits

    result =
      if precision > 0 do
        "#{integer_with_delimiter}.#{List.first(decimal_parts)}"
      else
        integer_with_delimiter
      end

    "#{unit}#{result}"
  end
end
