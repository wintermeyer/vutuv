defmodule VutuvWeb.PostLive.FeedRailArrangementTest do
  @moduledoc """
  Arranging the feed's rail: the order its cards sit in, folding one to its
  heading, putting one away and fetching it back.

  Every assertion goes through the rendered page, because the arrangement is a
  promise about what the reader sees on their *next* visit — a test that called
  `Posts.save_feed_rail/2` and read the column back would pass with the whole
  panel unwired. So each case drives the control and then mounts the feed a
  second time.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Posts
  alias VutuvWeb.FeedRailHelpers

  defp order(html) do
    Regex.scan(~r/data-rail-block="([a-z_]+)"/, html) |> Enum.map(&List.last/1)
  end

  # A card is folded when its heading is there and its body is not, which is
  # what the caret's own `aria-expanded` says — so the test reads the same
  # attribute a screen reader does rather than guessing from the markup.
  defp folded(live) do
    for key <- ~w(followed_tags unread hidden_tags words newcomers sources),
        FeedRailHelpers.folded?(live, key),
        do: key
  end

  defp with_tag(conn) do
    {conn, user} = create_and_login_user(conn)
    tag = insert(:tag, name: "Bremen")
    Vutuv.Tags.follow_tag(user, tag)
    # The "New here" card greets only members who show a face, and it is the
    # first block in the shipped order — without one the order under test is
    # missing its head.
    insert(:activated_user, first_name: "New", last_name: "Face", avatar: "selfie.jpg")

    %{conn: conn, user: user}
  end

  describe "the order" do
    test "starts at the shipped one and survives a drag", %{conn: conn} do
      %{conn: conn} = with_tag(conn)

      {:ok, live, html} = live(conn, ~p"/feed")
      assert ["followed_tags", "hidden_tags", "words", "newcomers", "sources"] = order(html)

      # The two switch panels ship folded to their heading; everything a reader
      # actually reads ships open.
      assert folded(live) == ~w(hidden_tags sources)

      # What the browser pushes after a drop: the sequence of what was on
      # screen, which is exactly what the hook reads off the DOM.
      render_hook(live, "rail-reorder", %{
        "order" => ["newcomers", "followed_tags", "sources", "words", "hidden_tags"]
      })

      {:ok, _live, html} = live(conn, ~p"/feed")
      assert ["newcomers", "followed_tags", "sources", "words", "hidden_tags"] = order(html)
    end

    # The rail is half conditional, so a drag only ever names the cards that
    # were showing. Calibrated by replacing `rearrange_feed_rail/2` with
    # `%{rail | order: moved}`: the unlisted card is then dropped and re-appended
    # at the end, and this reads "unread" last instead of first.
    test "a card that is not showing keeps its place", %{conn: conn} do
      %{conn: conn, user: user} = with_tag(conn)

      # "Not read yet" only renders while something is waiting, so it is absent
      # from every drag this reader can perform.
      {:ok, live, html} = live(conn, ~p"/feed")
      refute "unread" in order(html)

      render_hook(live, "rail-reorder", %{
        "order" => ["newcomers", "followed_tags", "words", "sources", "hidden_tags"]
      })

      # "unread" keeps the second slot it holds in the shipped order, although
      # no drag could name it.
      assert %{order: ["newcomers", "unread", "followed_tags", "words", "sources", "hidden_tags"]} =
               Posts.feed_rail(Repo.reload!(user), ~w(
                 followed_tags unread hidden_tags words newcomers sources
               ))
    end
  end

  describe "folding a card" do
    test "keeps the heading and drops the body, both across a reload", %{conn: conn} do
      %{conn: conn} = with_tag(conn)

      {:ok, live, html} = live(conn, ~p"/feed")
      assert html =~ "Bremen"

      live |> element(~s(#rail-followed_tags button[phx-click="rail-collapse"])) |> render_click()

      {:ok, live, html} = live(conn, ~p"/feed")
      assert html =~ ~s(data-rail-block="followed_tags")
      refute html =~ "Bremen"

      live |> element(~s(#rail-followed_tags button[phx-click="rail-collapse"])) |> render_click()
      {:ok, _live, html} = live(conn, ~p"/feed")
      assert html =~ "Bremen"
    end
  end

  describe "putting a card away" do
    test "takes it out of the rail and offers it back by name", %{conn: conn} do
      %{conn: conn} = with_tag(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")

      live |> element(~s(#rail-followed_tags button[phx-click="rail-remove"])) |> render_click()

      {:ok, live, html} = live(conn, ~p"/feed")
      refute "followed_tags" in order(html)
      # The chip is the only way back, so it has to name the card the reader
      # removed rather than its key.
      assert html =~ "Tags you follow"
      assert has_element?(live, "#rail-restore-followed_tags")

      live |> element("#rail-restore-followed_tags") |> render_click()

      {:ok, _live, html} = live(conn, ~p"/feed")
      assert "followed_tags" in order(html)
      refute html =~ ~s(id="rail-removed")
    end

    # A folded card that is put away and fetched back would otherwise return as
    # a heading with nothing under it, from a fold the reader has long
    # forgotten. Calibrated by dropping the `collapsed:` half of the remove
    # handler: "Bremen" is then still missing after the restore.
    test "unfolds it, so it comes back the way it went in", %{conn: conn} do
      %{conn: conn} = with_tag(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")

      live |> element(~s(#rail-followed_tags button[phx-click="rail-collapse"])) |> render_click()
      live |> element(~s(#rail-followed_tags button[phx-click="rail-remove"])) |> render_click()
      live |> element("#rail-restore-followed_tags") |> render_click()

      {:ok, _live, html} = live(conn, ~p"/feed")
      assert html =~ "Bremen"
    end
  end

  # vutuv is a German site, and `gettext.extract --merge` fuzzy-fills a new
  # msgid with the translation of whatever it looks similar to — "Remove
  # %{card}" arrived as "%{country} entfernen", with the wrong placeholder. Only
  # naming the strings catches that; an English render stays green either way.
  describe "the German render" do
    test "names the three controls and the way back", %{conn: conn} do
      %{conn: conn} = with_tag(conn)
      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de;q=0.9")

      {:ok, live, html} = live(conn, ~p"/feed")

      assert html =~ "Tags, denen Sie folgen einklappen"
      assert html =~ "Tags, denen Sie folgen entfernen"
      assert html =~ "Ziehen, oder die Pfeiltasten benutzen"

      live |> element(~s(#rail-followed_tags button[phx-click="rail-remove"])) |> render_click()

      {:ok, _live, html} = live(conn, ~p"/feed")
      assert html =~ "Weggelegt:"
    end

    test "calls the phone's sheet a filter, not the act of filtering", %{conn: conn} do
      %{conn: conn} = with_tag(conn)
      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de;q=0.9")

      {:ok, live, _html} = live(conn, ~p"/feed")
      html = live |> element("#open-filter-sheet") |> render_click()

      # The admin newsletter page's identically spelled msgid is the verb
      # ("Filtern"); this one is the noun, which is why it has its own context.
      assert html =~ ~s(aria-label="Filter")
      assert html =~ "Fertig"
    end
  end
end
