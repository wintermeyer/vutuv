defmodule VutuvWeb.FeedPageSizeTest do
  @moduledoc """
  How long the feed is, and who decides.

  One number does it all — the arrival, every "Load more", a source switch, an
  opened calendar day — and the member owns it (`Vutuv.Prefs`, default 10, up to
  250). What must stay true: the **document** carries exactly that many cards,
  the socket adds nothing behind the reader's back, and the control under the
  timeline both stores the choice and shows it at once.

  It replaces `feed_first_render_test.exs`, which guarded the split this
  removed: the dead render used to carry ten of a forty-card arrival and the
  socket appended the other thirty on connect.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Accounts
  alias Vutuv.Posts
  alias Vutuv.Prefs

  # The shipped default, read off the registry so the test cannot drift from it.
  @default Prefs.pref!(:feed_page_size).default

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

  defp set_page_size(user, size) do
    {:ok, user} = Accounts.update_user(user, %{"feed_page_size" => size})
    user
  end

  describe "the default arrival" do
    test "the document carries ten posts and the socket adds none", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fill_feed(user, @default + 15)

      html = conn |> get(~p"/feed") |> html_response(200)

      assert feed_cards(html) == @default,
             "the HTML document must carry #{@default} cards, got #{feed_cards(html)}"

      {:ok, live, joined} = live(conn, ~p"/feed")

      assert feed_cards(joined) == @default

      assert feed_cards(render(live)) == @default,
             "nothing may be appended after the join — the arrival is what was asked for"
    end

    test "a feed shorter than one page shows what there is", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fill_feed(user, 3)

      {:ok, live, html} = live(conn, ~p"/feed")

      assert feed_cards(html) == 3
      assert feed_cards(render(live)) == 3
    end

    test "Load more adds one more page of the same size", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fill_feed(user, @default * 2 + 1)

      {:ok, live, _html} = live(conn, ~p"/feed")

      html = live |> element("#load-more") |> render_click()

      assert feed_cards(html) == @default * 2
    end
  end

  describe "the member's own size" do
    test "a stored size is what the document carries", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      set_page_size(user, 25)
      fill_feed(user, 30)

      html = conn |> get(~p"/feed") |> html_response(200)

      assert feed_cards(html) == 25
    end

    test "the agent-format sibling follows it too", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      set_page_size(user, 25)
      fill_feed(user, 30)

      body = conn |> get(~p"/feed.json") |> json_response(200)

      assert length(body["posts"]) == 25
    end
  end

  describe "the control under the timeline" do
    test "it marks the size the reader holds", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fill_feed(user, 3)

      {:ok, live, _html} = live(conn, ~p"/feed")

      assert live |> element(~s{#feed-page-size button[data-page-size="#{@default}"]}) |> render() =~
               ~s(aria-pressed="true")
    end

    test "pressing a bigger number lengthens the feed and stores the choice", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fill_feed(user, 40)

      {:ok, live, _html} = live(conn, ~p"/feed")

      html = render_click(live, "feed-page-size", %{"size" => "25"})

      assert feed_cards(html) == 25,
             "the new length must be on the screen, not promised for later"

      assert Accounts.get_user(user.id).feed_page_size == 25

      # …and it is the length the next arrival carries as well.
      assert conn |> get(~p"/feed") |> html_response(200) |> feed_cards() == 25
    end

    test "pressing a smaller number shortens it again", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      set_page_size(user, 50)
      fill_feed(user, 60)

      {:ok, live, html} = live(conn, ~p"/feed")
      assert feed_cards(html) == 50

      assert feed_cards(render_click(live, "feed-page-size", %{"size" => "10"})) == 10
    end

    test "a value outside the registry's bounds changes nothing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      fill_feed(user, 15)

      {:ok, live, _html} = live(conn, ~p"/feed")

      assert feed_cards(render_click(live, "feed-page-size", %{"size" => "5000"})) == @default
      assert is_nil(Accounts.get_user(user.id).feed_page_size)
    end

    test "an empty feed offers no length to set", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")

      refute has_element?(live, "#feed-page-size")
    end
  end

  describe "the size travels with the reader" do
    test "an opened calendar day pages at it, and a change reloads that day", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = insert(:activated_user)
      follow!(user, author)

      # Built from the Berlin clock the app stamps, never `Date.utc_today/0`.
      day = Date.add(Vutuv.BerlinTime.today(), -1)

      for i <- 1..40 do
        author
        |> create_post!(%{body: "Gestern #{i}"})
        |> Vutuv.PostsHelpers.place_post_on_day!(day, i)
      end

      {:ok, live, _html} = live(conn, ~p"/feed?day=#{Date.to_iso8601(day)}")

      # A change of size reloads the day the reader is standing in, not the
      # present behind it.
      html = render_click(live, "feed-page-size", %{"size" => "25"})

      assert feed_cards(html) == 25
      assert html =~ "Gestern"
    end

    test "a source switch asks for the reader's size", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      user = set_page_size(user, 25)
      fill_feed(user, 30)

      {:ok, live, _html} = live(conn, ~p"/feed")

      # The band's own source rows reload the timeline; whichever control did
      # it, the page is the reader's length.
      page = Posts.feed_page(user, limit: Prefs.feed_page_size(user), filter: :all)
      assert length(page.entries) == 25

      assert feed_cards(render(live)) == 25
    end
  end
end
