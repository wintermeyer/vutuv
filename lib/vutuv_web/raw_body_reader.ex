defmodule VutuvWeb.RawBodyReader do
  @moduledoc """
  The endpoint's `Plug.Parsers` body reader: passes every body through
  unchanged, but keeps a copy of the **raw bytes** for the ActivityPub inboxes
  in `conn.private[:fediverse_raw_body]`.

  HTTP-signature verification (`Vutuv.Fediverse.HttpSignature`) must hash the
  body exactly as sent — after `Plug.Parsers` has consumed it into
  `body_params`, the original bytes are otherwise gone. Only those paths pay
  the copy; every other request streams through untouched.

  **All four inbox routes, not two.** This used to match `[_slug, "actor",
  "inbox"]` and `["system", "inbox"]` only, so the organization inbox (four
  segments, `router.ex`) and the tag inbox (two, on the `tags.` host) never got
  their bytes kept. That is not a missing optimisation: with no body,
  `HttpSignature.valid?/2` dropped `digest` from the headers it requires and
  `check_digest/2` answered `:ok` for a `nil` body, so those two inboxes
  verified a signature over the headers alone and accepted **any** payload
  carrying them. `valid?/2` now refuses a POST whose body was not captured, so
  a future route added without a clause here fails closed instead of silently
  trusting its callers.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} -> {:ok, chunk, store(conn, chunk)}
      {:more, chunk, conn} -> {:more, chunk, store(conn, chunk)}
      other -> other
    end
  end

  @doc "The cached raw body (binary), or nil off the inbox path."
  def raw_body(%Plug.Conn{private: %{fediverse_raw_body: iodata}}),
    do: IO.iodata_to_binary(iodata)

  def raw_body(_conn), do: nil

  # A member's actor inbox.
  defp store(%Plug.Conn{path_info: [_slug, "actor", "inbox"]} = conn, chunk),
    do: keep(conn, chunk)

  # A page's actor inbox (issue #1334) — four segments, which is why the clause
  # above never matched it.
  defp store(%Plug.Conn{path_info: ["organizations", _slug, "actor", "inbox"]} = conn, chunk),
    do: keep(conn, chunk)

  # The installation-wide inbox (issue #1073) verifies the very same signature,
  # so it needs the very same copy of the bytes.
  defp store(%Plug.Conn{path_info: ["system", "inbox"]} = conn, chunk), do: keep(conn, chunk)

  # A topic's inbox, routed on the `tags.` host as two segments.
  defp store(%Plug.Conn{path_info: [_slug, "inbox"]} = conn, chunk), do: keep(conn, chunk)

  defp store(conn, _chunk), do: conn

  defp keep(conn, chunk) do
    collected = conn.private[:fediverse_raw_body] || []
    Plug.Conn.put_private(conn, :fediverse_raw_body, [collected, chunk])
  end
end
