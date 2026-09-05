defmodule VutuvWeb.PostLive.FeedFilterPanelTest do
  @moduledoc """
  The rail's filter surface after the redesign: three cards became one row and
  a panel.

  What the old shape cost was paid by the member who filters nothing — three
  card frames, two "just now in your feed" lists meaning opposite things, and a
  paragraph explaining a mechanism nobody had asked for. So the first thing
  these tests pin down is the empty state: no card at all, one quiet line. The
  rest follow the row into the panel and check that a rule written there is the
  same deny list `/settings/filters` keeps.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.ContentFilters

  defp logged_in(conn) do
    {conn, user} = create_and_login_user(conn)
    friend = insert(:activated_user, first_name: "Lena", last_name: "Loud")
    insert(:follow, follower: user, followee: friend)
    %{conn: conn, user: user, friend: friend}
  end

  describe "the rail" do
    test "carries no filter card at all while nothing is hidden", %{conn: conn} do
      %{conn: conn} = logged_in(conn)

      {:ok, live, html} = live(conn, ~p"/feed")

      # The three retired cards are gone from the arrangeable rail, so a member
      # who never filters carries none of their chrome.
      refute html =~ ~s(data-rail-block="words")
      refute html =~ ~s(data-rail-block="hidden_tags")
      refute html =~ ~s(data-rail-block="sources")
      refute has_element?(live, "#feed-filter-row")

      # What is left is one line, and it opens the same panel.
      assert has_element?(live, "#feed-filter-link")
    end

    test "shows the row with a count once a rule exists", %{conn: conn} do
      %{conn: conn, user: user} = logged_in(conn)
      {:ok, _} = ContentFilters.create_filter(user, %{kind: :keyword, pattern: "Krypto"})

      {:ok, live, _html} = live(conn, ~p"/feed")

      assert has_element?(live, ~s(#feed-filter-row[data-filter-count="1"]))
      refute has_element?(live, "#feed-filter-link")
    end
  end

  describe "the German render" do
    # vutuv is a German site, and ConnTest speaks English unless told otherwise
    # — so the one place the count is read as a sentence gets read in the
    # language most visitors see it in.
    test "names the row and its count in German", %{conn: conn} do
      %{conn: conn, user: user} = logged_in(conn)
      {:ok, _} = ContentFilters.create_filter(user, %{kind: :keyword, pattern: "Krypto"})

      # `logged_in/1` already sent a response through this conn, so the header
      # goes on a recycled one — otherwise Plug refuses to touch it.
      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de")
      {:ok, _live, html} = live(conn, ~p"/feed")

      assert html =~ "Ausgeblendet"
      assert html =~ "1 Regel"
    end
  end

  describe "the panel" do
    test "opens from the row and holds words, tags and sources", %{conn: conn} do
      %{conn: conn, user: user} = logged_in(conn)
      {:ok, _} = ContentFilters.create_filter(user, %{kind: :keyword, pattern: "Krypto"})

      {:ok, live, html} = live(conn, ~p"/feed")

      # Closed at mount: a reader who never opens it pays none of its queries.
      refute html =~ ~s(id="filter-panel")

      html = live |> element("#feed-filter-row") |> render_click()

      assert html =~ ~s(id="filter-panel")
      assert html =~ ~s(id="filter-band-words")
      assert html =~ ~s(id="filter-band-tags")

      html = live |> element("#filter-tab-sources") |> render_click()
      assert html =~ ~s(id="filter-band")

      html = live |> element("#close-filter-panel") |> render_click()
      refute html =~ ~s(id="filter-panel")
    end

    test "opens from the quiet line when there is no row yet", %{conn: conn} do
      %{conn: conn} = logged_in(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")

      assert live |> element("#feed-filter-link") |> render_click() =~ ~s(id="filter-panel")
    end

    test "a rule added in the panel reaches the member's own deny list", %{conn: conn} do
      %{conn: conn, user: user} = logged_in(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")
      live |> element("#feed-filter-link") |> render_click()

      live
      |> element(~s(#filter-band-words form))
      |> render_submit(%{"pattern" => "Kryptowährung"})

      assert [%{kind: :keyword, pattern: "Kryptowährung"}] = ContentFilters.list_for_user(user)

      # And the row it just earned says so, without a reload.
      assert has_element?(live, ~s(#feed-filter-row[data-filter-count="1"]))
    end
  end
end
