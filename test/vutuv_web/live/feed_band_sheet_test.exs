defmodule VutuvWeb.PostLive.FeedBandSheetTest do
  @moduledoc """
  The band on a phone.

  The rail is `hidden md:block`, so without a way in from the timeline itself a
  phone could reach none of it — and since the source tabs are gone, could not
  look at one source alone at all. That is the whole point of these tests: the
  button exists, it opens the same panel the desktop row opens, and a switch
  inside it writes through the same contexts.

  The sheet stopped being a shape of its own with the filter redesign: the
  panel is one markup that lands as a sheet under `sm` and as a drawer above
  it, because two answers to the same question is how only one of them ended up
  findable.
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

  test "the filter button opens the panel and closes it again", %{conn: conn} do
    %{conn: conn} = with_friend(conn)

    {:ok, live, html} = live(conn, ~p"/feed")

    # Closed at mount, so a reader who never opens it pays none of its queries.
    refute html =~ ~s(id="filter-panel")
    assert has_element?(live, "#open-filter-sheet")

    html = live |> element("#open-filter-sheet") |> render_click()

    assert html =~ ~s(id="filter-panel")
    # Both halves of the words tab, and the sources one a tab away.
    assert html =~ ~s(id="filter-band-words")
    assert html =~ ~s(id="filter-band-tags")
    assert live |> element("#filter-tab-sources") |> render_click() =~ ~s(id="filter-band")

    html = live |> element("#close-filter-panel") |> render_click()
    refute html =~ ~s(id="filter-panel")
  end

  test "a rule added in the sheet reaches the member's own deny list", %{conn: conn} do
    %{conn: conn, user: user} = with_friend(conn)

    {:ok, live, _html} = live(conn, ~p"/feed")
    live |> element("#open-filter-sheet") |> render_click()

    live
    |> element(~s(#filter-band-words form))
    |> render_submit(%{"pattern" => "Kryptowährung"})

    assert [%{kind: :keyword, pattern: "Kryptowährung"}] = ContentFilters.list_for_user(user)
  end

  test "switching a source off in the sheet moves the timeline", %{conn: conn} do
    %{conn: conn, friend: friend} = with_friend(conn)
    {:ok, post} = Posts.create_post(friend, %{body: "loud and clear"})

    {:ok, live, _html} = live(conn, ~p"/feed")
    assert has_element?(live, "#feed-posts [id*='#{post.id}']")

    live |> element("#open-filter-sheet") |> render_click()
    live |> element("#filter-tab-sources") |> render_click()

    live
    |> element(~s(#filter-band input[phx-value-source="vutuv"]))
    |> render_click()

    refute has_element?(live, "#feed-posts [id*='#{post.id}']")
  end
end
