defmodule VutuvWeb.Teaser.Mp4 do
  @moduledoc """
  An MP4's running time, read from its `mvhd` box (timescale and duration)
  without an external tool. `nil` where the box is missing or malformed.
  """

  @doc "The running time in milliseconds, or `nil`."
  def duration_ms(bytes) when is_binary(bytes) do
    with {pos, 4} <- :binary.match(bytes, "mvhd"),
         <<version, _flags::24, rest::binary>> <-
           binary_part(bytes, pos + 4, byte_size(bytes) - pos - 4),
         {:ok, timescale, duration} when timescale > 0 <- fields(version, rest) do
      div(duration * 1_000, timescale)
    else
      _ -> nil
    end
  end

  defp fields(0, <<_created::32, _modified::32, timescale::32, duration::32, _::binary>>),
    do: {:ok, timescale, duration}

  defp fields(1, <<_created::64, _modified::64, timescale::32, duration::64, _::binary>>),
    do: {:ok, timescale, duration}

  defp fields(_version, _rest), do: :error
end
