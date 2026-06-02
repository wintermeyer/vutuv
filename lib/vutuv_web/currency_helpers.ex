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

    integer_with_delimiter =
      integer_part
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.map(&Enum.reverse/1)
      |> Enum.reverse()
      |> Enum.map_join(delimiter, &Enum.join/1)

    result =
      if precision > 0 do
        "#{integer_with_delimiter}.#{List.first(decimal_parts)}"
      else
        integer_with_delimiter
      end

    "#{unit}#{result}"
  end
end
