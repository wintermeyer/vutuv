defmodule VutuvWeb.ControllerHelpers do
  @moduledoc """
  Small helpers shared across controllers.
  """

  alias Plug.Conn

  @doc """
  Returns the path of the request's `Referer` header, falling back to
  `fallback` when there is no usable referer.

  `fallback` is computed by the caller (typically a `~p` verified route) so the
  route sigil expands at the call site with that controller's correct default.
  """
  def referrer_url(%Conn{} = conn, fallback) when is_binary(fallback) do
    case Conn.get_req_header(conn, "referer") do
      [referer | _] -> URI.parse(referer).path || fallback
      [] -> fallback
    end
  end
end
