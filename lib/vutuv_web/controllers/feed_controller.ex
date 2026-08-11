defmodule VutuvWeb.FeedController do
  @moduledoc """
  The RSS 2.0 post feeds (see `VutuvWeb.Feeds`): `/:slug/posts/feed.xml`
  per member, `/posts/feed.xml` site-wide. Served outside the browser
  pipeline — a reader sending `Accept: application/rss+xml` must not be
  turned away by `accepts ["html"]` — so slug resolution happens here with
  plain-text 404s (the HTML error page needs the pipeline's flash).

  A member's feed serves like their `.md` profile does: never hidden, but
  marked with the robots directives and Content-Signals of the member's two
  opt-outs (`noindex?` for search engines, `noai?` for AI use).
  """

  use VutuvWeb, :controller

  alias Vutuv.Posts
  alias VutuvWeb.ContentPolicy
  alias VutuvWeb.Feeds

  @feed_limit 20

  def user(conn, %{"slug" => slug}) do
    case Vutuv.Repo.get_by(Vutuv.Accounts.User, username: slug) do
      %{email_confirmed?: true} = author ->
        posts = Posts.recent_public_posts(author, limit: @feed_limit)
        send_feed(conn, Feeds.render_user_feed(author, posts), author.noindex?, author.noai?)

      _unknown_or_unactivated ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not Found")
    end
  end

  @doc """
  A page's own posts (issue #1334). The **anonymous** view — the same set the
  page's agent formats serve — so a post still held by moderation is absent
  here even though the organization's own publishers see it on the page.

  Gated on `public_visible?/1` rather than on `agent_visible?/1`: a feed is a
  subscription somebody asked for, not a crawl, so the page's `geo?` opt-out
  (which is about machine readers helping themselves) does not silence it. The
  page's `seo?` choice still rides along in the headers below, exactly as a
  member's `noindex?` does on theirs.
  """
  def organization(conn, %{"slug" => slug}) do
    organization = Vutuv.Organizations.get_organization_by_slug(slug)

    if organization && Vutuv.Organizations.public_visible?(organization) do
      posts = Posts.organization_posts_page(organization, nil, limit: @feed_limit).entries

      send_feed(
        conn,
        Feeds.render_organization_feed(organization, posts),
        not organization.seo?,
        not organization.geo?
      )
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not Found")
    end
  end

  # The site-wide feed only aggregates members who opted out of nothing
  # (Posts.recent_public_posts/2), so it carries the permissive signals.
  def site(conn, _params) do
    posts = Posts.recent_public_posts(:all, limit: @feed_limit)
    send_feed(conn, Feeds.render_site_feed(posts), false, false)
  end

  defp send_feed(conn, body, noindex?, noai?) do
    conn
    |> put_resp_content_type("application/rss+xml")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> put_resp_header("content-signal", ContentPolicy.signal_header(noindex?, noai?))
    # The XML document itself is never a search result, so every feed is
    # noindex — a permissive member's feed used to carry no robots header at
    # all and got filed by Google as a "duplicate without a canonical" of the
    # profile. The member's search choice still reaches crawlers through the
    # Content-Signal above; their AI choice keeps its robots directives.
    |> ContentPolicy.put_robots_header(true, noai?)
    |> send_resp(200, body)
  end
end
