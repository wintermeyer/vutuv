defmodule VutuvWeb.PostLive.FeedTrendingTagsTest do
  @moduledoc """
  The row of tags that are suddenly busy on other servers, under the feed's tag
  card (issue #2129).

  What decides *what* is on offer is `Vutuv.Tags.TrendingTest`'s business. What
  this pins is the row itself: that a press follows the tag and names the
  servers it is busy on, that the figures are formatted, that the German is the
  German, and that the socket knows who is pressing.

  `async: false`: it flips `:tag_source_servers`, `:fetch_external_tag_posts`,
  `:fetch_trending_tags` and `:external_tag_req_options`, all of them
  application env and therefore global — see the note in
  `Vutuv.Tags.ExternalTagClientTest`, which flips the same seam.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.ExternalTagHelpers

  alias Vutuv.Sessions
  alias Vutuv.Tags
  alias Vutuv.Tags.Trending

  @big "troet.example"
  @small "nrw.example"

  # As measured on 10 September 2026: 1,084 uses against a median of 3.
  @warntag [1084, 16, 11, 3, 1, 3, 2]

  # Everything the trending pill may wear that the pill above it does not: it is
  # the one that lays a sparkline out beside its label. Named as the whole
  # allowed difference rather than as a list of size spellings — an allowlist of
  # utilities to compare reads green for every spelling nobody thought of.
  @layout_extras MapSet.new(~w(flex max-w-full items-center gap-1.5))

  setup %{conn: conn} do
    put_config(:fetch_external_tag_posts, true)
    put_config(:fetch_trending_tags, true)
    put_config(:tag_source_servers, [@big, @small])

    crowd = fn host ->
      sample_statuses(host, 20, ~w(a.example b.example c.example d.example e.example))
    end

    stub_servers(%{
      @big => %{trends: [{"warntag", @warntag}], samples: %{"warntag" => crowd.(@big)}},
      @small => %{trends: [{"warntag", @warntag}], samples: %{"warntag" => crowd.(@small)}}
    })

    Trending.refresh()

    {conn, user} = create_and_login_user(conn)
    %{conn: conn, user: user}
  end

  defp pill(live), do: element(live, "#trending-tags button")

  defp classes(live, selector) do
    [element] = live |> render() |> elements(selector)

    element |> attribute("class") |> String.split() |> MapSet.new()
  end

  # A tag on a post in the reader's own feed, which is what the card offers a
  # few pixels above the trending row — the pill #2180 measures against.
  defp tag_on_the_page(user) do
    friend = insert(:activated_user)
    insert(:follow, follower: user, followee: friend)

    name = Vutuv.Factory.unique_tag_name("Bremen")
    Vutuv.PostsHelpers.create_post!(friend, %{body: "moin", tags: name})

    name
  end

  describe "the row" do
    test "offers what is spiking, with the week it was judged on", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/feed")

      assert html =~ "Very busy on other servers right now:"
      assert render(pill(live)) =~ "warntag"

      # Six quiet strokes plus today, and today is the tall one — the evidence
      # for "suddenly" rather than "a lot".
      bars = live |> element("#trending-tags button span[aria-hidden]") |> render()
      assert bars =~ "height:100%"
      assert length(Regex.scan(~r/height:/, bars)) == 7
    end

    test "says the figures in grouped form, never as run-together digits", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/feed")

      # 2 × 1,084 across the two servers, against 2 × 3 on an ordinary day.
      assert render(pill(live)) =~
               "2,168 uses today on 2 servers, against 6 on an ordinary day"
    end

    test "draws nothing at all when the feature is switched off", %{conn: conn} do
      put_config(:fetch_trending_tags, false)

      {:ok, _live, html} = live(conn, ~p"/feed")

      refute html =~ "Very busy on other servers right now:"
    end

    # An intranet installation names no servers at all (`SourceServers`'s empty
    # list is a real setting), so nobody is asked and the empty state below
    # would be a nightly report about servers this installation never reads.
    test "draws nothing at all when no server is configured to ask", %{conn: conn} do
      put_config(:tag_source_servers, [])

      {:ok, _live, html} = live(conn, ~p"/feed")

      refute html =~ "Very busy on other servers right now:"
    end

    # Issue #2165: a tag qualifies on today's volume against its own six-day
    # median, so shortly after midnight nothing can clear the bar. The row used
    # to take its label with it, which reads as breakage rather than as quiet.
    test "keeps its place and says why when there is nothing to offer", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/feed")

      # Following the one tag on offer empties it, exactly as midnight does.
      render_click(pill(live))
      html = render(live)

      assert html =~ "Very busy on other servers right now:"

      assert html =~
               "Nothing yet today. A topic has to run well ahead of its own last week, which takes a few hours."

      refute has_element?(live, "#trending-tags button")
    end
  end

  describe "one press" do
    test "follows the tag and names the servers it is busy on", %{conn: conn, user: user} do
      {:ok, live, _html} = live(conn, ~p"/feed")

      render_click(pill(live))

      assert [tag] = Tags.followed_tags(user)
      assert tag.name == "warntag"
      assert tag.slug == "warntag"

      sources = user |> Tags.tag_follow(tag.id) |> Tags.tag_follow_sources()
      assert Tags.local_tag_follow_source() in sources
      assert @big in sources

      # And it is a followed tag like any other from here on: the chip above
      # counts its servers, and the row no longer offers it. What the row shows
      # instead is the empty-state test's business (issue #2165).
      assert render(live) =~ "tag-sources-chip-#{tag.id}"
      refute has_element?(live, "#trending-tags button")
    end

    test "a pushed name nobody is offering follows nothing", %{conn: conn, user: user} do
      {:ok, live, _html} = live(conn, ~p"/feed")

      render_click(live, "follow-trending-tag", %{"name" => "hausgemacht"})

      assert Tags.followed_tags(user) == []
      assert Vutuv.Tags.Tag |> Vutuv.Repo.all() |> Enum.all?(&(&1.name != "hausgemacht"))
    end
  end

  describe "German" do
    test "the row's own words are translated", %{conn: conn} do
      {:ok, live, html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> live(~p"/feed")

      assert html =~ "Gerade sehr aktiv auf anderen Servern:"

      # The separator inverts between locales, so a figure formatted with the
      # wrong rules is misread rather than untidy.
      assert render(pill(live)) =~
               "warntag folgen. Heute 2.168 Beiträge auf 2 Servern, an einem gewöhnlichen Tag 6."
    end

    # A short new msgid is the likeliest thing `gettext.extract --merge` fuzzy-
    # fills with a neighbour's translation, and the least likely to be noticed —
    # so the empty row's German is asserted by name.
    test "the empty row says so in German too", %{conn: conn} do
      {:ok, live, _html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> live(~p"/feed")

      render_click(pill(live))
      html = render(live)

      assert html =~ "Gerade sehr aktiv auf anderen Servern:"

      assert html =~
               "Heute noch nichts. Ein Thema muss deutlich über seiner eigenen Vorwoche liegen, und das dauert ein paar Stunden."
    end
  end

  # Issue #2180: the card stacks three rows of pills and the bottom one was
  # drawn to a recipe of its own — bigger type, more padding, a 40px box — so in
  # a 309px rail each trending tag landed on a line of its own while the tags
  # above sat three to a row.
  describe "the pill" do
    test "is the same size as the tags offered a few pixels above it", %{conn: conn, user: user} do
      name = tag_on_the_page(user)

      {:ok, live, _html} = live(conn, ~p"/feed")

      trending = classes(live, "#trending-tags button")
      offered = classes(live, ~s(#rail-followed_tags button[phx-value-name="#{name}"]))

      # Both directions: the trending pill may add the layout its sparkline
      # needs and nothing else, and it may drop nothing the pill above wears.
      assert MapSet.difference(trending, offered) == @layout_extras
      assert MapSet.difference(offered, trending) == MapSet.new()
    end

    test "sizes the seven-day sparkline to fit that pill", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/feed")

      bars = live |> element("#trending-tags button span[aria-hidden]") |> render()

      # The sparkline is as tall as the pill's own line box (h-4 = 1rem, the
      # `text-xs` line height) and all seven strokes are hairlines, so the week
      # rides inside the pill instead of setting its size.
      assert bars =~ "h-4"
      assert length(Regex.scan(~r/w-0\.5/, bars)) == 7
    end
  end

  describe "the viewer" do
    test "is resolved from the session token, not from a user_id", %{conn: conn, user: user} do
      # The press writes somebody's follow, so who the socket thinks it is
      # matters. Revoking the session server-side (a remote logout, #794) must
      # take the socket with it, even though the cookie still names the member.
      user |> Sessions.list_active() |> Enum.each(&Sessions.revoke/1)

      assert {:error, {:redirect, _to}} = live(conn, ~p"/feed")
    end
  end
end
