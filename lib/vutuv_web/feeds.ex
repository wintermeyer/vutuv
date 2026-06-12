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

  alias Vutuv.Posts
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.UserHelpers
  alias VutuvWeb.Xml

  @doc "The one source of a member's feed path (controller, head tag, llms.txt)."
  def user_feed_path(user), do: "/#{user.active_slug}/posts/feed.xml"

  @doc "The site-wide feed path."
  def site_feed_path, do: "/posts/feed.xml"

  def render_user_feed(author, posts) do
    name = UserHelpers.full_name(author)

    render_feed(
      title: "#{name} · vutuv",
      link: AgentDocs.abs_url("/" <> author.active_slug),
      self: AgentDocs.abs_url(user_feed_path(author)),
      description: "Posts by #{name} on vutuv",
      posts: posts
    )
  end

  def render_site_feed(posts) do
    render_feed(
      title: "vutuv · latest posts",
      link: AgentDocs.abs_url("/"),
      self: AgentDocs.abs_url(site_feed_path()),
      description: "The latest public posts on vutuv",
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
      "  <description>#{Xml.escape(opts[:description])}</description>\n",
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
    title = "#{UserHelpers.full_name(post.user)} · #{Date.to_iso8601(post.published_on)}"

    [
      "  <item>\n",
      "    <title>#{Xml.escape(title)}</title>\n",
      "    <link>#{Xml.escape(permalink)}</link>\n",
      ~s(    <guid isPermaLink="true">#{Xml.escape(permalink)}</guid>\n),
      "    <pubDate>#{rfc1123(post.inserted_at)}</pubDate>\n",
      "    <dc:creator>#{Xml.escape(UserHelpers.full_name(post.user))}</dc:creator>\n",
      Enum.map(post.tags, &"    <category>#{Xml.escape(&1.name)}</category>\n"),
      "    <description>#{Xml.escape(AgentDocs.excerpt(post.body))}</description>\n",
      "    <content:encoded><![CDATA[#{cdata_safe(rendered_body(post))}]]></content:encoded>\n",
      "  </item>\n"
    ]
  end

  defp rendered_body(post) do
    post.body
    |> VutuvWeb.Markdown.render_post(post.images)
    |> Phoenix.HTML.safe_to_string()
    |> absolutize_urls()
  end

  # Root-relative src/href (post images, in-app links) must be absolute in
  # a feed — readers resolve nothing. Protocol-relative (`//host`) URLs are
  # left alone.
  defp absolutize_urls(html) do
    String.replace(html, ~r{(src|href)="/(?!/)}, "\\1=\"#{VutuvWeb.Endpoint.url()}/")
  end

  # A literal "]]>" in the rendered body would close the CDATA section.
  defp cdata_safe(html), do: String.replace(html, "]]>", "]]]]><![CDATA[>")

  defp rfc1123(%NaiveDateTime{} = naive),
    do: Calendar.strftime(naive, "%a, %d %b %Y %H:%M:%S GMT")
end
