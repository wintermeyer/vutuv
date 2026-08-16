defmodule VutuvWeb.Plug.TagHost do
  @moduledoc """
  Sends every readable page asked for on the **tag host** to the same page on
  the site.

  A topic's ActivityPub identity lives on `tags.<our host>` (issue #1330),
  which is its own WebFinger authority and publishes actors, not pages. The app
  answering there is the same app, though, so every route that host had not
  claimed simply fell through and rendered: `https://tags.vutuv.de/` served the
  whole start page — a second copy of the site under a hostname no reader was
  ever meant to see, a duplicate for a crawler, and for a member a session
  cookie that lives on the apex and therefore signs them out.

  It is wired into the `:browser` pipeline and nowhere else, and that is the
  entire rule. The machine documents — WebFinger, the actor endpoints,
  robots.txt, the `.well-known` files — run through `:machine_docs` instead, so
  no fetch that federation depends on can be caught by this. Same path, same
  query, 301: the shape the `vutuv.com` vhost already redirects with, and
  permanent because this host will never carry a page.

  The one address the tag host does publish to readers and servers alike,
  `/<tag>`, is negotiated in `VutuvWeb.FediverseController` instead — only that
  route knows the slug names a topic, and only it can send a reader to the
  topic's page rather than to the start page.
  """

  alias Vutuv.Fediverse
  alias VutuvWeb.Endpoint

  def init(opts), do: opts

  def call(conn, _opts) do
    if Fediverse.tag_host?(conn.host) do
      conn
      |> Plug.Conn.put_status(:moved_permanently)
      |> Phoenix.Controller.redirect(external: site_url() <> path_with_query(conn))
      |> Plug.Conn.halt()
    else
      conn
    end
  end

  defp site_url, do: String.trim_trailing(Endpoint.url(), "/")

  defp path_with_query(%{request_path: path, query_string: ""}), do: path
  defp path_with_query(%{request_path: path, query_string: query}), do: path <> "?" <> query
end
