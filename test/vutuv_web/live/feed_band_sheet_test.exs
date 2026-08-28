defmodule VutuvWeb.PostLive.FeedBandSheetTest do
  @moduledoc """
  The band on a phone.

  The rail the band normally lives in is `hidden md:block`, so without this
  sheet a phone has no way to reach any of it — and since the source tabs are
  gone, no way to look at one source alone at all. That is the whole point of
  these tests: the button exists, it opens the three cards, and a switch inside
  the sheet writes through the same contexts the rail's does.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.ContentFilters
  alias Vutuv.Posts

  defp with_friend(conn) do
    {conn, user} = create_and_login_user(conn)
    friend = insert(:activated_user, first_name: "Lena", last_name: "Loud")
    insert(:follow, follower: user, followee: friend)

    %{conn: conn, user: user, friend: friend}
  end

  test "the filter button opens the sheet and closes it again", %{conn: conn} do
    %{conn: conn} = with_friend(conn)

    {:ok, live, html} = live(conn, ~p"/feed")

    # Closed at mount, so a reader who never opens it pays none of its queries.
    refute html =~ ~s(id="band-sheet")
    assert has_element?(live, "#open-filter-sheet")

    html = live |> element("#open-filter-sheet") |> render_click()

    assert html =~ ~s(id="band-sheet")
    # All three cards, not just the sources one.
    assert html =~ ~s(id="sheet-band")
    assert html =~ ~s(id="sheet-band-words")
    assert html =~ ~s(id="sheet-band-tags")

    html = live |> element("#close-band-sheet") |> render_click()
    refute html =~ ~s(id="band-sheet")
  end

  test "a rule added in the sheet reaches the member's own deny list", %{conn: conn} do
    %{conn: conn, user: user} = with_friend(conn)

    {:ok, live, _html} = live(conn, ~p"/feed")
    live |> element("#open-filter-sheet") |> render_click()

    live
    |> element(~s(#sheet-band-words form))
    |> render_submit(%{"pattern" => "Kryptowährung"})

    assert [%{kind: :keyword, pattern: "Kryptowährung"}] = ContentFilters.list_for_user(user)
  end

  test "switching a source off in the sheet moves the timeline", %{conn: conn} do
    %{conn: conn, friend: friend} = with_friend(conn)
    {:ok, post} = Posts.create_post(friend, %{body: "loud and clear"})

    {:ok, live, _html} = live(conn, ~p"/feed")
    assert has_element?(live, "#feed-posts [id*='#{post.id}']")

    live |> element("#open-filter-sheet") |> render_click()

    live
    |> element(~s(#sheet-band input[phx-value-source="vutuv"]))
    |> render_click()

    refute has_element?(live, "#feed-posts [id*='#{post.id}']")
  end
end
