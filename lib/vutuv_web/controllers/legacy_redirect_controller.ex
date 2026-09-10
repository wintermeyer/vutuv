defmodule VutuvWeb.LegacyRedirectController do
  @moduledoc """
  Where every retired public URL keeps its 301, so a page that goes away leaves
  its address behind rather than a 404. Today that is the pre-2026 URL scheme
  (profiles and their sub-pages lived under /users/:slug, login under
  /sessions/new, search under /search_queries), /listings/most_followed_users,
  the retired most-followed listing, and the press area's four addresses, which
  became the Media Kit's (issue #2100).

  Mostly GET-only: forms always re-render against the new paths, so links and
  bookmarks are what need redirects. The one POST is the pre-LiveView search
  form, which 303s into the live search so a form rendered by the previous
  release keeps working across a deploy.

  Agent-format siblings ride along on their own: `VutuvWeb.Plug.AgentFormat`
  appends the requested extension to a redirect's location, so a retired
  `.md` address lands on the successor's `.md` rather than on its HTML.

  Destinations are built as strings rather than through the function that owns
  the path (`Vutuv.PressKit.page_path/1` and its like): those dispatch on a
  loaded record, and a retired address must forward on the slug it was given
  without reading a row — a renamed or deleted owner should reach the new URL
  and get its answer there, not a 404 here.
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

  # The pre-2026 API served a public vCard at /api/1.0/users/:slug/vcard;
  # search engines still hold such URLs. The profile's vCard sibling is the
  # canonical successor.
  def api_vcard(conn, %{"slug" => slug}), do: permanent(conn, "/" <> encode(slug) <> ".vcf")

  def search(conn, _params), do: permanent(conn, "/search")

  # The most-followed listing, retired in favour of the member directory: it
  # answered "who else is here?" with a follower ranking of the top 1,000, and
  # /system/members answers it for everybody, filed A-Z and searchable by name.
  # The URL sat in the sitemap and in /llms.txt for months, so it keeps a 301
  # rather than a 404.
  def most_followed_users(conn, _params), do: permanent(conn, ~p"/system/members")

  # The press area, renamed to the Media Kit (issue #2100). Only the address
  # moved: the same controller, the same shelves and the same documents answer
  # at `/media-kit`. `/:slug/press` was in the sitemap and in /llms.txt.
  def media_kit(conn, %{"slug" => slug}),
    do: permanent(conn, "/" <> encode(slug) <> "/media-kit")

  def organization_media_kit(conn, %{"slug" => slug}),
    do: permanent(conn, "/organizations/" <> encode(slug) <> "/media-kit")

  def organization_media_kit_edit(conn, %{"slug" => slug}),
    do: permanent(conn, "/organizations/" <> encode(slug) <> "/media-kit/edit")

  def settings_media_kit(conn, _params), do: permanent(conn, ~p"/settings/media-kit")

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
