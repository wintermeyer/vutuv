defmodule Vutuv.Http do
  @moduledoc """
  Shared helpers for the `Req`-based outbound fetchers (web verification,
  fediverse, social feeds).
  """

  @doc """
  A `Req` `into:` collector that accumulates the response body up to `max_bytes`
  and **halts** the stream once that ceiling is crossed, so a hostile or
  accidental large body is dropped during receipt rather than buffered whole and
  truncated after the fact. Pass it as `into: Vutuv.Http.capped_collector(max)`;
  the caller still slices `body` to the exact cap (the final chunk can overshoot).
  """
  def capped_collector(max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    fn {:data, data}, {req, resp} ->
      body = (resp.body || "") <> data
      resp = %{resp | body: body}

      if byte_size(body) >= max_bytes,
        do: {:halt, {req, resp}},
        else: {:cont, {req, resp}}
    end
  end
end
