defmodule VutuvWeb.LegacyRedirectController do
  @moduledoc """
  301s for the pre-2026 URL scheme: profiles and their sub-pages lived under
  /users/:slug, login under /sessions/new, and search under /search_queries.

  GET-only by design. Forms always re-render against the new paths, so only
  links and bookmarks need redirects; replaying POST bodies across a 301 is
  not reliable anyway.
  """

  use VutuvWeb, :controller

  def user(conn, %{"slug" => slug}) do
    permanent(conn, "/" <> encode(slug))
  end

  def user_subpage(conn, %{"slug" => slug, "rest" => rest}) do
    rest =
      case Enum.map(rest, &encode/1) do
        # The followees page was renamed to "following" when it moved.
        ["followees" | tail] -> ["following" | tail]
        encoded -> encoded
      end

    permanent(conn, Enum.join(["", encode(slug) | rest], "/"))
  end

  def login(conn, _params), do: permanent(conn, "/login")

  def search(conn, _params), do: permanent(conn, "/search")

  def search_query(conn, %{"id" => id}), do: permanent(conn, "/search/" <> encode(id))

  defp permanent(conn, path) do
    path =
      case conn.query_string do
        "" -> path
        query_string -> path <> "?" <> query_string
      end

    conn
    |> put_status(:moved_permanently)
    |> redirect(to: path)
    |> halt()
  end

  # Wildcard segments arrive decoded; re-encode them so the Location header
  # stays a well-formed path even for exotic input.
  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
