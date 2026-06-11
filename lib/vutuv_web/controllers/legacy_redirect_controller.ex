defmodule VutuvWeb.LegacyRedirectController do
  @moduledoc """
  301s for the pre-2026 URL scheme: profiles and their sub-pages lived under
  /users/:slug, login under /sessions/new, and search under /search_queries.

  Mostly GET-only: forms always re-render against the new paths, so links and
  bookmarks are what need redirects. The one POST is the pre-LiveView search
  form, which 303s into the live search so a form rendered by the previous
  release keeps working across a deploy.
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

  def search_query(conn, %{"id" => id}), do: permanent(conn, search_path(id))

  # A stored-query URL: /search/:id carried the query value as the id, so it
  # replays as a live search for the same value.
  def search_show(conn, %{"id" => id}), do: permanent(conn, search_path(id))

  # The previous release's search form POSTs here during a blue/green switch;
  # 303 so the browser re-issues it as a GET against the live search.
  def search_post(conn, params) do
    value = get_in(params, ["search_query", "value"]) || ""

    conn
    |> put_status(:see_other)
    |> redirect(to: search_path(value))
    |> halt()
  end

  defp search_path(value) do
    case String.trim(value) do
      "" -> "/search"
      value -> "/search?q=" <> URI.encode_www_form(value)
    end
  end

  defp permanent(conn, path) do
    path =
      case conn.query_string do
        "" -> path
        query_string -> path <> if(path =~ "?", do: "&", else: "?") <> query_string
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
