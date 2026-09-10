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

    test "draws nothing at all when this installation reads no other servers", %{conn: conn} do
      put_config(:fetch_trending_tags, false)

      {:ok, _live, html} = live(conn, ~p"/feed")

      refute html =~ "Very busy on other servers right now:"
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
      # counts its servers, and the row no longer offers it.
      html = render(live)
      assert html =~ "tag-sources-chip-#{tag.id}"
      refute html =~ "trending-tags"
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
