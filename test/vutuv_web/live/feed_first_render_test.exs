defmodule VutuvWeb.FeedFirstRenderTest do
  @moduledoc """
  What the **document** carries against what the **arrival** carries.

  Rendering a post card costs ~10 ms of server time on production (measured
  2026-08-31), so the forty cards a `/feed` arrival used to put in the HTML were
  about 400 ms of the wait before anything painted — to draw thirty-seven cards
  below a fold that shows two or three. The dead render now carries
  `@first_render_size` and the socket fills the arrival up to `@first_page_size`
  the moment it connects.

  What must stay true: the reader still ends up with a whole arrival, the fill
  lands **below** what they are looking at, and it never repeats a card the
  short page already showed.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias VutuvWeb.PostLive.Feed

  # The two numbers under test, read off the module so the test cannot drift
  # from it — and asserted against each other, because the whole design is that
  # one is smaller than the other.
  @first_render 10
  @first_page 40

  defp feed_cards(html) do
    ~r/id="feed-(?:post|repost|remote|boost)-/
    |> Regex.scan(html)
    |> length()
  end

  # `n` posts by somebody the reader follows, oldest first so the newest is last.
  defp fill_feed(reader, n) do
    author = insert(:activated_user)
    follow!(reader, author)

    for i <- 1..n do
      create_post!(author, %{body: "Beitrag Nummer #{i}"})
    end
  end

  describe "the document carries a screenful, not the whole arrival" do
    test "the dead render stops at the first-render size", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fill_feed(user, @first_page + 5)

      html = conn |> get(~p"/feed") |> html_response(200)

      assert feed_cards(html) == @first_render,
             "the HTML document must carry #{@first_render} cards, got #{feed_cards(html)}"
    end

    test "the connected arrival is filled back up to the full page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fill_feed(user, @first_page + 5)

      {:ok, live, html} = live(conn, ~p"/feed")

      # The join renders the short page, then `:fill_arrival` appends the rest.
      assert feed_cards(html) == @first_render

      filled = render(live)

      assert feed_cards(filled) == @first_page,
             "the socket must fill the arrival to #{@first_page}, got #{feed_cards(filled)}"
    end

    test "a feed with less than a screenful owes nothing and asks for nothing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fill_feed(user, 3)

      {:ok, live, html} = live(conn, ~p"/feed")

      assert feed_cards(html) == 3
      assert feed_cards(render(live)) == 3, "a short feed must not grow a second page"
    end
  end

  describe "the fill is an ordinary older page" do
    test "it appends below the short page and repeats nothing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fill_feed(user, @first_page + 5)

      {:ok, live, _html} = live(conn, ~p"/feed")
      html = render(live)

      ids = Regex.scan(~r/id="(feed-[a-z]+-[0-9a-f-]+)"/, html, capture: :all_but_first)
      assert length(ids) == length(Enum.uniq(ids)), "the fill must not repeat a card"

      # Newest first, and the newest post is the one the reader arrived for, so
      # it must be at the top rather than somewhere in the filled tail.
      assert feed_cards(html) == @first_page
      newest = "Beitrag Nummer #{@first_page + 5}"
      oldest_shown = "Beitrag Nummer #{@first_page + 5 - @first_page + 1}"
      assert html =~ newest
      assert html =~ oldest_shown

      {newest_at, _} = :binary.match(html, newest)
      {oldest_at, _} = :binary.match(html, oldest_shown)
      assert newest_at < oldest_at, "the fill belongs below what the document already showed"
    end

    test "Load more still picks up from where the fill stopped", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fill_feed(user, @first_page + 15)

      {:ok, live, _html} = live(conn, ~p"/feed")
      assert feed_cards(render(live)) == @first_page

      html = live |> element("#load-more") |> render_click()

      assert feed_cards(html) == @first_page + 15,
             "after the fill, Load more must add the remaining posts"
    end
  end

  describe "the fill is owed to one page, not to whatever is on screen" do
    test "an opened calendar day is not filled with cards from before it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = insert(:activated_user)
      follow!(user, author)

      # Two days, so the opened one really does have older posts behind it —
      # which is the whole spill this guards against. Built from the Berlin
      # clock the app stamps, never `Date.utc_today/0`.
      today = Vutuv.BerlinTime.today()
      yesterday = Date.add(today, -1)
      before_that = Date.add(today, -2)

      quiet_day =
        for i <- 1..3 do
          author
          |> create_post!(%{body: "Gestern #{i}"})
          |> Vutuv.PostsHelpers.place_post_on_day!(yesterday, i)
        end

      for i <- 1..20 do
        author
        |> create_post!(%{body: "Vorgestern #{i}"})
        |> Vutuv.PostsHelpers.place_post_on_day!(before_that, i)
      end

      {:ok, live, _html} = live(conn, ~p"/feed")

      # The fill message sits in the mailbox behind anything the reader does
      # first. Opening a day is the one that must not be extended.
      render_click(live, "cal-day", %{"date" => Date.to_iso8601(yesterday)})
      opened = render(live)
      assert feed_cards(opened) == length(quiet_day)
      refute opened =~ "Vorgestern"

      # Now let a fill owed to the arrival arrive late.
      send(live.pid, :fill_arrival)
      after_stale = render(live)

      assert feed_cards(after_stale) == length(quiet_day),
             "a fill owed to the arrival must not extend the day the reader opened"

      refute after_stale =~ "Vorgestern",
             "the day must not gain posts from before it"
    end
  end

  describe "the agent-format siblings are unchanged" do
    test "/feed.json still carries the whole arrival", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fill_feed(user, @first_page + 5)

      # The document siblings are not a browser arrival and have no socket to be
      # filled by, so they keep asking for the full page.
      assert Posts.feed_page(user, limit: Feed.first_page_size()).entries
             |> length() == @first_page

      body = conn |> get(~p"/feed.json") |> json_response(200)
      assert length(body["posts"]) == @first_page
    end
  end
end
