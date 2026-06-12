defmodule VutuvWeb.FeedController do
  @moduledoc """
  The RSS 2.0 post feeds (see `VutuvWeb.Feeds`): `/:slug/posts/feed.xml`
  per member, `/posts/feed.xml` site-wide. Served outside the browser
  pipeline — a reader sending `Accept: application/rss+xml` must not be
  turned away by `accepts ["html"]` — so slug resolution happens here with
  plain-text 404s (the HTML error page needs the pipeline's flash).

  A noindexed member's feed serves like their `.md` profile does: marked
  `noindex` with all-no Content-Signals, but not hidden.
  """

  use VutuvWeb, :controller

  alias Vutuv.Posts
  alias VutuvWeb.ContentPolicy
  alias VutuvWeb.Feeds

  @feed_limit 20

  def user(conn, %{"slug" => slug}) do
    case Vutuv.Repo.get_by(Vutuv.Accounts.User, active_slug: slug) do
      %{activated?: true} = author ->
        posts = Posts.recent_public_posts(author, limit: @feed_limit)
        send_feed(conn, Feeds.render_user_feed(author, posts), author.noindex?)

      _unknown_or_unactivated ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not Found")
    end
  end

  def site(conn, _params) do
    posts = Posts.recent_public_posts(:all, limit: @feed_limit)
    send_feed(conn, Feeds.render_site_feed(posts), false)
  end

  defp send_feed(conn, body, noindex?) do
    conn
    |> put_resp_content_type("application/rss+xml")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> put_resp_header("content-signal", ContentPolicy.signal_header(noindex?))
    |> maybe_noindex(noindex?)
    |> send_resp(200, body)
  end

  defp maybe_noindex(conn, true), do: put_resp_header(conn, "x-robots-tag", "noindex")
  defp maybe_noindex(conn, false), do: conn
end
