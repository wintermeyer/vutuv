defmodule VutuvWeb.PostCalendarControllerTest do
  @moduledoc """
  The public post calendar (`/system/posts`, `/system/posts/:year/:month` and
  `/system/posts/:year/:month/:day`): the crawl surface for the posts, the way
  `/system/members` is the crawl surface for the profiles.

  Two things these tests are mostly about. A day page lists **every** post
  written that day, and only a post whose author is open to search engines
  carries its permalink and its first line — the opt-out (`noindex?` on a
  member, `seo?` on a page) is exactly the set `Vutuv.Sitemap` advertises, so
  the two can never disagree about what a crawler may walk to. And a post
  published in a page's name is listed like a member's: the nullable
  `user_id`/`organization_id` pair drops organization rows out of any query
  that inner-joins `users`, silently.
  """

  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Posts.PostDenial
  alias Vutuv.Repo

  @day ~D[2026-03-17]
  @other_day ~D[2026-02-04]

  setup do
    author = insert_activated_user(first_name: "Greta", last_name: "Gradient")

    post =
      insert(:post,
        user: author,
        published_on: @day,
        body: "A bridge over the Rhine, and how it was built"
      )

    %{author: author, post: post}
  end

  describe "GET /system/posts (the overview)" do
    test "links every month that has posts and dims the rest", %{conn: conn} do
      # An activated author, here and everywhere below: an unconfirmed account
      # is listed nowhere on the site, so a post of theirs would be missing from
      # the calendar for a reason that has nothing to do with what is under test.
      insert(:post,
        user: insert_activated_user(),
        published_on: @other_day,
        body: "Something in February"
      )

      html = get(conn, ~p"/system/posts") |> html_response(200)

      assert html =~ "Post calendar"
      assert html =~ ~p"/system/posts/2026/3"
      assert html =~ ~p"/system/posts/2026/2"
      # A month nobody wrote in is a muted tile, never a link into an empty page.
      refute html =~ ~p"/system/posts/2026/7"
    end

    test "counts a post whose author opted out of search engines", %{conn: conn} do
      # The tile count is what decides whether a month is a link, so it counts
      # what the day page lists — not the narrower set the day page links.
      opted_out = insert_activated_user(noindex?: true)
      insert(:post, user: opted_out, published_on: @other_day, body: "Quiet one")

      html = get(conn, ~p"/system/posts") |> html_response(200)

      assert html =~ ~s(data-key="2026-02" data-count="1")
    end
  end

  describe "GET /system/posts/:year/:month (one month)" do
    test "links the days that have posts", %{conn: conn} do
      html = get(conn, ~p"/system/posts/2026/3") |> html_response(200)

      assert html =~ ~p"/system/posts/2026/3/17"
      refute html =~ ~p"/system/posts/2026/3/18"
      assert html =~ ~s(data-count="1")
    end

    test "a month with no posts renders its grid and says so", %{conn: conn} do
      html = get(conn, ~p"/system/posts/2026/7") |> html_response(200)

      assert html =~ "No posts in this month yet."
      refute html =~ ~p"/system/posts/2026/7/1"
    end

    test "an impossible month is a 404", %{conn: conn} do
      assert conn |> get(~p"/system/posts/2026/13") |> response(404)
      assert conn |> get("/system/posts/notayear/3") |> response(404)
    end
  end

  describe "GET /system/posts/:year/:month/:day (one day)" do
    test "lists the day's posts with their permalink and first line", %{
      conn: conn,
      post: post,
      author: author
    } do
      html = get(conn, ~p"/system/posts/2026/3/17") |> html_response(200)

      assert html =~ "A bridge over the Rhine"
      assert html =~ ~p"/#{author.username}/posts/#{post.id}"
      assert html =~ "Gradient"
    end

    test "a post from an author who opted out is listed but never linked", %{conn: conn} do
      opted_out = insert_activated_user(first_name: "Otto", last_name: "Opt-Out", noindex?: true)

      quiet =
        insert(:post, user: opted_out, published_on: @day, body: "Nobody may index this line")

      html = get(conn, ~p"/system/posts/2026/3/17") |> html_response(200)

      # Listed: the day says two posts were written, and names who wrote them.
      assert html =~ "Opt-Out"
      assert html =~ "Post not open to search engines"
      # Not linked, and not quoted: a permalink here would walk a crawler
      # straight past the opt-out, and the first line would put the post's own
      # words on an indexable page.
      refute html =~ ~p"/#{opted_out.username}/posts/#{quiet.id}"
      refute html =~ "Nobody may index this line"
    end

    test "lists a post published in an organization's name", %{conn: conn} do
      organization = insert(:organization, name: "Span AG", slug: "span-ag")

      post =
        insert(:post,
          user: nil,
          organization: organization,
          published_on: @day,
          body: "We finished the span"
        )

      html = get(conn, ~p"/system/posts/2026/3/17") |> html_response(200)

      assert html =~ "Span AG"
      assert html =~ "We finished the span"
      assert html =~ ~p"/organizations/span-ag/posts/#{post.id}"
    end

    test "a post nobody may read is nowhere in the calendar", %{conn: conn} do
      hidden =
        insert(:post, user: insert_activated_user(), published_on: @day, body: "Only for a few")

      Repo.insert!(%PostDenial{post_id: hidden.id, wildcard: "everyone"})

      html = get(conn, ~p"/system/posts/2026/3/17") |> html_response(200)
      refute html =~ "Only for a few"

      # And it is not in the count either, or the calendar would advertise a day
      # with one more post on it than anybody can see.
      month = get(conn, ~p"/system/posts/2026/3") |> html_response(200)
      assert month =~ ~s(data-count="1")
    end

    test "paginates a busy day and reaches the rest on page two", %{conn: conn} do
      # One over a page, so page two holds exactly one post and the pager has to
      # exist for it to be reachable at all — a crawler that never sees the
      # second page never sees those posts.
      per_page = Vutuv.PostCalendar.per_page()
      author = insert_activated_user()

      for n <- 1..per_page do
        insert(:post, user: author, published_on: @day, body: "Bulk post #{n}")
      end

      first = get(conn, ~p"/system/posts/2026/3/17") |> html_response(200)
      assert first =~ "?page=2"

      second = get(conn, ~p"/system/posts/2026/3/17?page=2") |> html_response(200)
      assert second =~ "Bulk post" or second =~ "A bridge over the Rhine"

      # Every post of the day is on one page or the other.
      for n <- 1..per_page do
        assert first =~ "Bulk post #{n}" or second =~ "Bulk post #{n}"
      end
    end

    test "an impossible day is a 404", %{conn: conn} do
      assert conn |> get(~p"/system/posts/2026/2/30") |> response(404)
    end
  end

  describe "in German" do
    # vutuv is a German site, and `gettext.extract --merge` fuzzy-fills a new
    # msgid with the translation of whatever string it looks similar to — this
    # page's own labels came back as "Veröffentlicht" and "Als %{name}
    # veröffentlichen", both of them confident nonsense that no English check
    # would ever see. So every new German string is asserted by name.
    setup %{conn: conn} do
      %{conn: put_req_header(conn, "accept-language", "de-DE,de")}
    end

    test "the overview, a month and a day are German", %{conn: conn} do
      overview = get(conn, ~p"/system/posts") |> html_response(200)
      assert overview =~ "Beitragskalender"
      assert overview =~ "Alle öffentlichen Beiträge auf vutuv"

      month = get(conn, ~p"/system/posts/2026/3") |> html_response(200)
      assert month =~ "Beiträge im März 2026"
      assert month =~ "Benachbarte Monate"

      day = get(conn, ~p"/system/posts/2026/3/17") |> html_response(200)
      assert day =~ "Beiträge vom"
      assert day =~ "Ein Beitrag"
    end

    test "an opted-out author's row says so in German", %{conn: conn} do
      opted_out = insert_activated_user(noindex?: true)
      insert(:post, user: opted_out, published_on: @day, body: "Nicht indexieren")

      html = get(conn, ~p"/system/posts/2026/3/17") |> html_response(200)
      assert html =~ "Beitrag ohne Freigabe für Suchmaschinen"
    end
  end

  describe "the calendar as a crawl surface" do
    test "the footer links it from every page", %{conn: conn} do
      html = get(conn, ~p"/") |> html_response(200)
      assert html =~ ~p"/system/posts"
    end

    test "the sitemap advertises the overview", %{conn: conn} do
      xml = get(conn, ~p"/sitemaps/static.xml") |> response(200)
      assert xml =~ "/system/posts</loc>"
    end

    test "links exactly the posts the sitemap advertises", %{conn: conn, post: post} do
      # The two answers to "may a crawler walk to this post" have to agree, or
      # the calendar hands a crawler a URL the sitemap deliberately withholds.
      # They agree by construction now — both read `Identity.indexable?/1` —
      # and this asserts it over the pair that used to be spelled twice.
      opted_out = insert_activated_user(noindex?: true)
      quiet = insert(:post, user: opted_out, published_on: @day, body: "Not for the index")

      day = get(conn, ~p"/system/posts/2026/3/17") |> html_response(200)
      sitemap = get(conn, ~p"/sitemaps/posts-1.xml") |> response(200)

      assert day =~ post.id
      assert sitemap =~ post.id

      refute day =~ quiet.id
      refute sitemap =~ quiet.id
    end
  end
end
