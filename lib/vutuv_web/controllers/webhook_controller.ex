defmodule VutuvWeb.WebhookController do
  @moduledoc """
  Machine-to-machine ingestion endpoints. `bounces/2` receives the raw DSN
  messages production Postfix pipes out of the bounce mailbox (see
  `scripts/postfix/vutuv-bounce` and `Vutuv.Notifications.Bounces`).

  Auth is a bearer token (`config :vutuv, :bounce_webhook_token`, from the
  BOUNCE_WEBHOOK_TOKEN env var in production); compared in constant time.
  Without a configured token the endpoint plays dead (404), so a missing
  env var fails closed. The route runs outside the browser pipeline — no
  session, no CSRF — and reads the body raw (`message/rfc822` passes
  through `Plug.Parsers` untouched).
  """

  use VutuvWeb, :controller

  # Generous cap; a DSN is small, but it embeds the bounced original.
  @max_body 1_000_000

  def bounces(conn, _params) do
    with {:ok, token} <- configured_token(),
         :ok <- authorize(conn, token) do
      {conn, raw} = read_raw_body(conn)

      case Vutuv.Notifications.Bounces.record(raw) do
        {:ok, _} -> send_resp(conn, 200, "ok")
        {:error, :unparseable} -> send_resp(conn, 422, "unparseable")
      end
    else
      :disabled -> send_resp(conn, 404, "not found")
      :unauthorized -> send_resp(conn, 401, "unauthorized")
    end
  end

  defp configured_token do
    case Application.get_env(:vutuv, :bounce_webhook_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> :disabled
    end
  end

  defp authorize(conn, token) do
    with ["Bearer " <> presented] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(presented, token) do
      :ok
    else
      _ -> :unauthorized
    end
  end

  defp read_raw_body(conn) do
    case Plug.Conn.read_body(conn, length: @max_body) do
      {:ok, body, conn} -> {conn, body}
      # Truncated oversize body: the DSN report fields sit near the top, so
      # parse what we got rather than failing the whole bounce.
      {:more, partial, conn} -> {conn, partial}
      {:error, _} -> {conn, ""}
    end
  end
end
