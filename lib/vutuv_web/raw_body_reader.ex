defmodule VutuvWeb.RawBodyReader do
  @moduledoc """
  The endpoint's `Plug.Parsers` body reader: passes every body through
  unchanged, but keeps a copy of the **raw bytes** for the ActivityPub inbox
  (`POST /:slug/actor/inbox`) in `conn.private[:fediverse_raw_body]`.

  HTTP-signature verification (`Vutuv.Fediverse.HttpSignature`) must hash the
  body exactly as sent — after `Plug.Parsers` has consumed it into
  `body_params`, the original bytes are otherwise gone. Only the inbox path
  pays the copy; every other request streams through untouched.
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

  defp store(%Plug.Conn{path_info: [_slug, "actor", "inbox"]} = conn, chunk) do
    collected = conn.private[:fediverse_raw_body] || []
    Plug.Conn.put_private(conn, :fediverse_raw_body, [collected, chunk])
  end

  defp store(conn, _chunk), do: conn
end
