defmodule VutuvWeb.FeedControllerTest do
  @moduledoc """
  The RSS 2.0 feeds: one per member (/:slug/posts/feed.xml, original posts
  only) and the site-wide firehose (/posts/feed.xml). Full item content
  per the agent-readiness spec — readers and agents get the whole post,
  not a teaser. Served outside the browser pipeline (a reader sending
  `Accept: application/rss+xml` must not be 406'd away).
  """

  use VutuvWeb.ConnCase, async: true

  import Vutuv.PostsHelpers

  alias Vutuv.Posts

  @base "http://localhost:4001"

  setup do
    author = insert_activated_user(username: "feed_author", first_name: "Fiona")
    %{author: author}
  end

  describe "GET /:slug/posts/feed.xml" do
    test "answers RSS even to a reader that only accepts application/rss+xml", %{author: author} do
      create_post!(author, %{"body" => "Hello feed"})

      conn =
        build_conn()
        |> put_req_header("accept", "application/rss+xml")
        |> get("/feed_author/posts/feed.xml")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/rss+xml"
      assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
      assert conn.resp_body =~ ~s(<rss version="2.0")
      assert conn.resp_body =~ "<title>Fiona Test · vutuv</title>"
    end

    test "items carry the full rendered content, not a teaser", %{author: author} do
      create_post!(author, %{"body" => "Hello **world**\n\nSecond paragraph."})

      body = build_conn() |> get("/feed_author/posts/feed.xml") |> response(200)

      assert body =~ "<content:encoded><![CDATA["
      assert body =~ "<strong>world</strong>"
      assert body =~ "Second paragraph."
    end

    test "a book review's facts ride inside the item content", %{author: author} do
      create_post!(author, %{
        "body" => "Sehr lesenswert.",
        "review" => %{
          "kind" => "book",
          "identifier" => "978-3-16-148410-0",
          "title" => "Refactoring",
          "creator" => "Martin Fowler",
          "year" => "2018"
        }
      })

      body = build_conn() |> get("/feed_author/posts/feed.xml") |> Map.fetch!(:resp_body)

      assert body =~ "Book review"
      assert body =~ "Refactoring"
      assert body =~ "Martin Fowler"
      assert body =~ "ISBN 978-3-16-148410-0"
    end

    test "links and guids are absolute permalinks", %{author: author} do
      post = create_post!(author, %{"body" => "Linked"})

      body = build_conn() |> get("/feed_author/posts/feed.xml") |> response(200)

      assert body =~ "<link>#{@base}/feed_author/posts/#{post.id}</link>"
      assert body =~ ~s(<guid isPermaLink="true">#{@base}/feed_author/posts/#{post.id}</guid>)
      assert body =~ ~s(<atom:link href="#{@base}/feed_author/posts/feed.xml" rel="self")
    end

    test "root-relative URLs in the rendered body become absolute", %{author: author} do
      create_post!(author, %{"body" => "See [the tags](/tags) page"})

      body = build_conn() |> get("/feed_author/posts/feed.xml") |> response(200)

      assert body =~ ~s(href="#{@base}/tags")
    end

    # RSS readers treat <description> as entity-encoded HTML, so the
    # plain-text excerpt needs an HTML-escape layer under the XML one:
    # a bare `&` that survives XML-unescaping is invalid HTML (the W3C
    # validator flags it as "Named entity expected. Got none."), and an
    # unescaped `<div>` would be swallowed as a tag instead of shown.
    test "the description double-escapes & and < so the HTML layer stays valid", %{author: author} do
      create_post!(author, %{
        "body" => "Siehe https://example.com/a?b=1&smid=share und <div> Tags"
      })

      body = build_conn() |> get("/feed_author/posts/feed.xml") |> response(200)

      assert body =~
               "<description>Siehe https://example.com/a?b=1&amp;amp;smid=share " <>
                 "und &amp;lt;div&amp;gt; Tags</description>"
    end

    test "pubDate is RFC 1123", %{author: author} do
      create_post!(author, %{"body" => "Dated"})

      body = build_conn() |> get("/feed_author/posts/feed.xml") |> response(200)

      assert body =~ ~r|<pubDate>\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT</pubDate>|
    end

    test "restricted posts and other members' posts stay out", %{author: author} do
      other = insert_activated_user(username: "other_member")
      visible = create_post!(author, %{"body" => "Mine, public"})

      restricted =
        create_post!(author, %{
          "body" => "Mine, restricted",
          "denials" => [%{"wildcard" => "everyone"}]
        })

      foreign = create_post!(other, %{"body" => "Not mine"})

      body = build_conn() |> get("/feed_author/posts/feed.xml") |> response(200)

      assert body =~ visible.id
      refute body =~ restricted.id
      refute body =~ foreign.id
    end

    test "a member's replies stay out — the feed carries original posts only", %{author: author} do
      parent = create_post!(author, %{"body" => "The conversation starter"})
      {:ok, reply} = Posts.create_reply(author, parent, %{body: "Following myself up"})

      body = build_conn() |> get("/feed_author/posts/feed.xml") |> response(200)

      assert body =~ parent.id
      refute body =~ reply.id
    end

    # A subscriber wants the member's archive, not just the last fortnight, so
    # the author feeds carry a long tail — but an unbounded feed grows with the
    # account forever, so it stops at the newest @author_feed_limit posts.
    test "carries the newest 100 posts and stops there", %{author: author} do
      posts = for i <- 1..101, do: insert(:post, user: author, body: "Post #{i}")
      [oldest | _] = posts
      newest = List.last(posts)

      body = build_conn() |> get("/feed_author/posts/feed.xml") |> response(200)

      assert length(String.split(body, "<item>")) - 1 == 100
      assert body =~ newest.id
      refute body =~ oldest.id
    end

    test "an unknown or unactivated member 404s" do
      insert(:user, username: "sleepy_member")

      assert get(build_conn(), "/nobody_here/posts/feed.xml").status == 404
      assert get(build_conn(), "/sleepy_member/posts/feed.xml").status == 404
    end

    # The XML document itself is never a search result: every feed is served
    # noindex so Google does not file it as a "duplicate without a canonical"
    # of the profile (which is exactly what Search Console reported for
    # member feeds). The member's choices still flow into the Content-Signal
    # header and, for the AI axis, into the robots directives.
    test "a permissive member's feed is still marked noindex" do
      create_post!(insert_activated_user(username: "open_author"), %{"body" => "Open words"})

      conn = get(build_conn(), "/open_author/posts/feed.xml")

      assert conn.status == 200
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
      assert get_resp_header(conn, "content-signal") == ["ai-train=yes, search=yes, ai-input=yes"]
    end

    test "a noindexed member's feed serves, marked noindex, AI choice intact" do
      quiet = insert_activated_user(username: "quiet_author", noindex?: true, noai?: false)
      create_post!(quiet, %{"body" => "Quiet words"})

      conn = get(build_conn(), "/quiet_author/posts/feed.xml")

      assert conn.status == 200
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
      assert get_resp_header(conn, "content-signal") == ["ai-train=yes, search=no, ai-input=yes"]
    end

    test "an AI-opted-out member's feed combines noindex with the noai directives" do
      human = insert_activated_user(username: "human_author", noindex?: false, noai?: true)
      create_post!(human, %{"body" => "For people"})

      conn = get(build_conn(), "/human_author/posts/feed.xml")

      assert conn.status == 200
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, noai, noimageai"]
      assert get_resp_header(conn, "content-signal") == ["ai-train=no, search=yes, ai-input=no"]
    end
  end

  # `/:slug/posts.xml` is what people (and feed readers) guess for "this
  # member's posts as XML" — the W3C feed validator was pointed there and
  # choked on the generic <post_archive> agent document. The unscoped
  # archive's `.xml` sibling therefore hands the reader the real feed;
  # the other agent formats and the period-scoped archives are untouched.
  describe "GET /:slug/posts.xml" do
    test "redirects permanently to the RSS feed" do
      conn = get(build_conn(), "/feed_author/posts.xml")

      assert redirected_to(conn, 301) == "/feed_author/posts/feed.xml"
    end

    test "Accept: application/xml on the archive lands on the feed too" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/xml")
        |> get("/feed_author/posts")

      assert redirected_to(conn, 301) == "/feed_author/posts/feed.xml"
    end

    test "the other agent formats still serve the archive document", %{author: author} do
      create_post!(author, %{"body" => "Archived words"})

      for extension <- [".md", ".txt", ".json"] do
        conn = get(build_conn(), "/feed_author/posts" <> extension)

        assert conn.status == 200
        assert conn.resp_body =~ "Archived words"
      end
    end

    test "a period-scoped archive keeps its XML document", %{author: author} do
      post = create_post!(author, %{"body" => "Dated entry"})

      conn = get(build_conn(), "/feed_author/posts/#{post.published_on.year}.xml")

      assert conn.status == 200
      assert conn.resp_body =~ "<post_archive>"
    end
  end

  describe "GET /posts/feed.xml" do
    test "collects the latest public posts across members", %{author: author} do
      other = insert_activated_user(username: "second_author")
      mine = create_post!(author, %{"body" => "From Fiona"})
      theirs = create_post!(other, %{"body" => "From the other one"})

      conn = get(build_conn(), "/posts/feed.xml")

      assert conn.status == 200
      assert conn.resp_body =~ mine.id
      assert conn.resp_body =~ theirs.id
      assert get_resp_header(conn, "content-signal") == ["ai-train=yes, search=yes, ai-input=yes"]
      # The XML document itself never belongs in a search index.
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
    end

    # The member feed filters replies out (above); the firehose deliberately
    # keeps them — it answers "what is being posted here", not "who says what".
    test "keeps replies — the firehose carries every public post", %{author: author} do
      parent = create_post!(author, %{"body" => "Origin"})
      {:ok, reply} = Posts.create_reply(author, parent, %{body: "An answer"})

      body = build_conn() |> get("/posts/feed.xml") |> response(200)

      assert body =~ parent.id
      assert body =~ reply.id
    end

    # The aggregate feed carries one all-yes Content-Signal and cannot
    # signal per item, so members who opted out (of search engines or of
    # AI use) are left out entirely — same reasoning for both axes.
    test "skips noindexed members, AI-opted-out members and restricted posts", %{author: author} do
      quiet = insert_activated_user(username: "quiet_author", noindex?: true)
      quiet_post = create_post!(quiet, %{"body" => "Quiet words"})

      human = insert_activated_user(username: "human_author", noai?: true)
      human_post = create_post!(human, %{"body" => "For people only"})

      restricted =
        create_post!(author, %{
          "body" => "Restricted words",
          "denials" => [%{"wildcard" => "everyone"}]
        })

      body = build_conn() |> get("/posts/feed.xml") |> response(200)

      refute body =~ quiet_post.id
      refute body =~ human_post.id
      refute body =~ restricted.id
    end
  end

  describe "feed discovery in the HTML head" do
    test "the profile page advertises the member's feed", %{author: author} do
      create_post!(author, %{"body" => "Discoverable"})

      html = build_conn() |> get("/feed_author") |> html_response(200)

      assert html =~
               ~s(rel="alternate" type="application/rss+xml" href="/feed_author/posts/feed.xml")
    end

    test "the post archive advertises the member's feed" do
      html = build_conn() |> get("/feed_author/posts") |> html_response(200)

      assert html =~ ~s(href="/feed_author/posts/feed.xml")
    end

    # Autodiscovery is invisible; members who want to hand their feed URL to
    # someone need a link they can see and copy (the "Other formats" card).
    test "the profile offers the feed as a visible RSS chip", %{author: author} do
      create_post!(author, %{"body" => "Chip-worthy"})

      html = build_conn() |> get("/feed_author") |> html_response(200)

      assert html =~ ~r|<a[^>]*href="/feed_author/posts/feed\.xml"[^>]*>\s*RSS\s*</a>|
    end

    # Issue #1287 put the feed pill in the header of the Posts card, because the
    # rail card at the very foot of a long profile was not where anyone looked.
    # The pill then owned the loudest spot on the section for the rarer of the
    # two ways to follow a member from outside vutuv, so the header now signs
    # the way to the Subscribe card, which carries both.
    test "the Posts card points at the Subscribe card", %{author: author} do
      create_post!(author, %{"body" => "Subscribe-worthy"})

      document =
        build_conn()
        |> get("/feed_author")
        |> html_response(200)
        |> LazyHTML.from_document()

      link = LazyHTML.query(document, "#profile-posts #profile-subscribe-link")
      assert LazyHTML.attribute(link, "href") == ["#profile-subscribe"]

      # Never a dead jump. This member does not federate, so the card is the
      # feed alone — which is exactly the case that would break if the card
      # were still conditional on a Fediverse address.
      refute Enum.empty?(LazyHTML.query(document, "#profile-subscribe"))
      assert Enum.empty?(LazyHTML.query(document, "#profile-fediverse"))
    end

    test "the Subscribe card carries the feed", %{author: author} do
      create_post!(author, %{"body" => "Subscribe-worthy"})

      document =
        build_conn()
        |> get("/feed_author")
        |> html_response(200)
        |> LazyHTML.from_document()

      button = LazyHTML.query(document, "#profile-subscribe #profile-posts-feed")

      assert LazyHTML.attribute(button, "href") == ["/feed_author/posts/feed.xml"]
      # Icon-only would be a guess for anyone who does not know the glyph.
      assert LazyHTML.text(button) =~ "RSS"
      # The rail chip is a second link named "RSS" to the same URL, so this
      # one spells the action out — with the visible word inside the label.
      assert [label] = LazyHTML.attribute(button, "aria-label")
      assert label =~ "RSS"
      assert LazyHTML.attribute(button, "title") == [label]

      # A standalone reader wants the address pasted into its own "add feed"
      # box, so the absolute URL sits beside the pill as a copy target.
      url = LazyHTML.query(document, "#profile-posts-feed-url")
      assert LazyHTML.text(url) =~ @base <> "/feed_author/posts/feed.xml"
    end

    # The German is asserted by name because the extract fuzzy-matched
    # "Subscribe" to "Abbestellen" — unsubscribe, the opposite — and nothing
    # else in the build would have caught it.
    test "the German render names the card and the feed reader", %{author: author} do
      create_post!(author, %{"body" => "Abonnierbar"})

      html =
        build_conn()
        |> put_req_header("accept-language", "de-DE,de")
        |> get("/feed_author")
        |> html_response(200)

      assert html =~ "Abonnieren"
      # This member does not federate, so the feed is the card's only half
      # below the offer, and its heading must not offer an alternative to
      # nothing.
      assert html =~ "Mit einem RSS-Reader"
      refute html =~ "Oder mit einem RSS-Reader"
      refute html =~ "Abbestellen"

      # The account offer and the line that says what the rest is for.
      assert html =~ "Mit einem vutuv-Konto"
      assert html =~ "Kostenloses Konto erstellen"
      assert html =~ "Kein vutuv-Konto? Das geht auch:"
      # "Create a free account" fuzzy-matched the landing page's heading
      # ("Erstellen Sie Ihren Account"), which is a sentence, not a button.
      refute html =~ "Erstellen Sie Ihren Account"
    end

    test "the post archive carries the same feed button" do
      button =
        build_conn()
        |> get("/feed_author/posts")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#archive-feed")

      assert LazyHTML.attribute(button, "href") == ["/feed_author/posts/feed.xml"]
    end

    # A member with nothing to say yet still has a feed worth subscribing to,
    # but their profile renders no Posts card for a visitor and the Subscribe
    # card holds only the account offer — so the rail chip is the one visible
    # way to the feed.
    test "a visitor's empty profile keeps the rail chip when there is no Posts card" do
      html = build_conn() |> get("/feed_author") |> html_response(200)
      document = LazyHTML.from_document(html)

      assert Enum.empty?(LazyHTML.query(document, "#profile-posts"))
      assert Enum.empty?(LazyHTML.query(document, "#profile-posts-feed"))
      refute Enum.empty?(LazyHTML.query(document, "#profile-account"))
      assert html =~ ~r|<a[^>]*href="/feed_author/posts/feed\.xml"[^>]*>\s*RSS\s*</a>|
    end

    # Anonymous is the whole audience for this card, and an account is the best
    # answer it has: the posts arrive in a feed the reader can answer in. The
    # other two ways are what we offer people who do not want one, which the
    # card says in those words rather than leaving them to infer the ranking.
    test "the card offers an account first, and says what the rest is for", %{author: author} do
      create_post!(author, %{"body" => "Subscribe-worthy"})

      document =
        build_conn()
        |> get("/feed_author")
        |> html_response(200)
        |> LazyHTML.from_document()

      card = LazyHTML.query(document, "#profile-subscribe")
      assert LazyHTML.attribute(LazyHTML.query(card, "#profile-account-signup"), "href") == ["/"]
      assert LazyHTML.text(card) =~ "No vutuv account?"

      # The offer leads: it is the first heading in the card.
      assert [first | _] = LazyHTML.query(card, "h3") |> LazyHTML.text() |> String.split("\n")
      assert first =~ "vutuv account"
    end

    test "a signed-in reader is not sold an account they have", %{author: author} do
      create_post!(author, %{"body" => "Subscribe-worthy"})

      {conn, _reader} =
        build_conn() |> Plug.Test.init_test_session(%{}) |> create_and_login_user()

      document =
        conn
        |> get("/feed_author")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert Enum.empty?(LazyHTML.query(document, "#profile-account"))
      refute LazyHTML.text(LazyHTML.query(document, "#profile-subscribe")) =~ "No vutuv account?"
      # The feed half is still there, and with nothing above it it drops the "Or".
      refute Enum.empty?(LazyHTML.query(document, "#profile-posts-feed"))
    end
  end
end
