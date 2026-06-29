defmodule VutuvWeb.Plug.NewsletterClick do
  @moduledoc """
  Records a click on a vutuv.de link that came from a newsletter, then sends the
  visitor on to the link's real destination.

  Newsletter HTML mail rewrites every internal link so its `href` carries a
  signed `?nlt=` token naming the newsletter and the recipient
  (`VutuvWeb.NewsletterToken`). This plug runs on the `:browser` pipeline: when a
  GET request carries that parameter it logs the click
  (`Vutuv.Newsletters.record_click/3`, the path with the token stripped) and
  302-redirects to the same URL without the parameter. Stripping it keeps the
  visitor's address bar clean and stops a reload from double-counting; the token
  is the only thing the plug consumes, so the redirected request renders the page
  exactly as a normal visit would. A missing or invalid token is ignored — the
  request just falls through untouched — so an old or tampered link still works.

  Only `GET` is handled, so a form `POST` that happens to carry the parameter is
  never turned into a redirect.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Vutuv.Newsletters
  alias VutuvWeb.NewsletterToken

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    conn = fetch_query_params(conn)

    case conn.query_params[NewsletterToken.param()] do
      token when is_binary(token) -> handle_click(conn, token)
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp handle_click(conn, token) do
    case NewsletterToken.verify(token) do
      {:ok, newsletter_id, user_id} ->
        Newsletters.record_click(newsletter_id, user_id, conn.request_path)

      :error ->
        :ok
    end

    conn |> redirect(to: clean_path(conn)) |> halt()
  end

  # The same path with only the tracking parameter removed, so any other query
  # parameters the link carried are preserved.
  defp clean_path(conn) do
    case conn.query_params |> Map.delete(NewsletterToken.param()) |> URI.encode_query() do
      "" -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
  end
end
