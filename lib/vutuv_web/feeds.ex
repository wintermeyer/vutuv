defmodule VutuvWeb.Feeds do
  @moduledoc """
  RSS 2.0 renderers for the post feeds: one per member (original posts
  only) and the site-wide firehose. Items carry the **full** rendered
  post (`content:encoded`), not a teaser — "if you want agents to quote
  you fairly, give them the full content" — with every URL absolute.

  Bodies render through `VutuvWeb.Markdown.render_post/2` (the sanitizing
  renderer), never raw Earmark. `pubDate` comes from `inserted_at` (UTC):
  `published_on` is date-only and RSS wants a timestamp.
  """

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.SiteName
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.PostComponents
  alias VutuvWeb.PostTeaser
  alias VutuvWeb.UserHelpers
  alias VutuvWeb.Xml

  @doc "The one source of a member's feed path (controller, head tag, llms.txt)."
  def user_feed_path(user), do: "/#{user.username}" <> user_feed_suffix()

  @doc """
  What a member's feed path adds to their profile path.

  Split out so a caller holding a profile *URL* rather than a `%User{}` can
  reach the same feed — the landing page's RSS chip hangs off the configured
  example-profile URL, which may point at another installation entirely.
  """
  def user_feed_suffix, do: "/posts/feed.xml"

  @doc """
  The one source of an organization's feed path (issue #1334). Built on the
  **slug** path, like the post permalinks it lists, rather than on the page's
  opt-in root handle: a feed URL is subscribed to once and then re-fetched for
  years, so it gets the shape that works whether or not a handle was claimed.
  """
  def organization_feed_path(organization),
    do: "/organizations/#{organization.slug}" <> user_feed_suffix()

  @doc "The site-wide feed path."
  def site_feed_path, do: "/posts/feed.xml"

  def render_user_feed(author, posts) do
    name = UserHelpers.full_name(author)

    render_feed(
      title: "#{name} · #{SiteName.get()}",
      link: AgentDocs.abs_url("/" <> author.username),
      self: AgentDocs.abs_url(user_feed_path(author)),
      description: "Posts by #{name} on #{SiteName.get()}",
      posts: posts
    )
  end

  @doc """
  The feed of a page's own posts (issue #1334). An organization publishes under
  one name, which is the whole point of the feature, so a feed is the one
  distribution channel it should not have to do without.
  """
  def render_organization_feed(organization, posts) do
    render_feed(
      title: "#{organization.name} · #{SiteName.get()}",
      link: AgentDocs.abs_url(Organizations.canonical_path(organization)),
      self: AgentDocs.abs_url(organization_feed_path(organization)),
      description: "Posts by #{organization.name} on #{SiteName.get()}",
      posts: posts
    )
  end

  def render_site_feed(posts) do
    render_feed(
      title: "#{SiteName.get()} · latest posts",
      link: AgentDocs.abs_url("/"),
      self: AgentDocs.abs_url(site_feed_path()),
      description: "The latest public posts on #{SiteName.get()}",
      posts: posts
    )
  end

  defp render_feed(opts) do
    posts = Keyword.fetch!(opts, :posts)

    [
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      ~s(<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" ),
      ~s(xmlns:dc="http://purl.org/dc/elements/1.1/" ),
      ~s(xmlns:atom="http://www.w3.org/2005/Atom">\n),
      "<channel>\n",
      "  <title>#{Xml.escape(opts[:title])}</title>\n",
      "  <link>#{Xml.escape(opts[:link])}</link>\n",
      ~s(  <atom:link href="#{Xml.escape(opts[:self])}" rel="self" type="application/rss+xml"/>\n),
      "  <description>#{html_text(opts[:description])}</description>\n",
      last_build_date(posts),
      Enum.map(posts, &item/1),
      "</channel>\n</rss>\n"
    ]
    |> IO.iodata_to_binary()
  end

  # Deterministic (cache-friendly): the newest item's timestamp, not "now".
  defp last_build_date([]), do: ""

  defp last_build_date([newest | _]),
    do: "  <lastBuildDate>#{rfc1123(newest.inserted_at)}</lastBuildDate>\n"

  defp item(post) do
    permalink = AgentDocs.abs_url(Posts.path(post))
    author = UserHelpers.author_name(post)
    title = "#{author} · #{Date.to_iso8601(post.published_on)}"

    [
      "  <item>\n",
      "    <title>#{Xml.escape(title)}</title>\n",
      "    <link>#{Xml.escape(permalink)}</link>\n",
      ~s(    <guid isPermaLink="true">#{Xml.escape(permalink)}</guid>\n),
      "    <pubDate>#{rfc1123(post.inserted_at)}</pubDate>\n",
      "    <dc:creator>#{Xml.escape(author)}</dc:creator>\n",
      Enum.map(post.tags, &"    <category>#{Xml.escape(&1.name)}</category>\n"),
      "    <description>#{html_text(PostTeaser.line(post))}</description>\n",
      "    <content:encoded><![CDATA[#{cdata_safe(rendered_body(post))}]]></content:encoded>\n",
      "  </item>\n"
    ]
  end

  defp rendered_body(post) do
    body_html =
      post.body
      # An RSS reader is an anonymous viewer: only AI-released images may
      # render inline (the unreleased rest simply stays absent).
      |> VutuvWeb.Markdown.render_post(Posts.released_images(post))
      |> Phoenix.HTML.safe_to_string()

    # A review sidecar rides inside the item content (same as the federated
    # Note): RSS readers know nothing of review cards.
    (body_html <> PostComponents.review_content_html(post))
    |> absolutize_urls()
  end

  # Root-relative src/href (post images, in-app links) must be absolute in
  # a feed — readers resolve nothing. Protocol-relative (`//host`) URLs are
  # left alone.
  defp absolutize_urls(html) do
    VutuvWeb.Markdown.absolutize_html(html, VutuvWeb.Endpoint.url())
  end

  # A literal "]]>" in the rendered body would close the CDATA section.
  defp cdata_safe(html), do: String.replace(html, "]]>", "]]]]><![CDATA[>")

  # RSS readers interpret <description> as entity-encoded HTML, so plain
  # text needs an HTML-escape layer under the XML one: a bare `&` that
  # survives XML-unescaping is invalid HTML (the W3C validator flags it
  # as "Named entity expected"), and a `<div>` would be read as a tag.
  defp html_text(text), do: text |> Xml.escape() |> Xml.escape()

  defp rfc1123(%NaiveDateTime{} = naive),
    do: Calendar.strftime(naive, "%a, %d %b %Y %H:%M:%S GMT")
end
