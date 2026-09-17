defmodule VutuvWeb.InvestorsReachLiveTest do
  @moduledoc """
  The yearly reach card on `/system/investors` (`VutuvWeb.InvestorsReachLive`),
  embedded by the controller and mounted here with `live_isolated/3`.

  The card has to say what it is doing while the figure is being worked out,
  one step at a time, and then show the figure. Tests run without the
  background runner, so the view computes in place and `render_async/1` waits
  for it. The figures themselves are `Vutuv.PostAnalytics.YearTest`'s business;
  here only the card's states are checked, which is also why nothing below
  depends on the calendar year.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.PostAnalytics.Year

  defp mount_card(conn, locale \\ "en") do
    live_isolated(conn, VutuvWeb.InvestorsReachLive, session: %{"locale" => locale})
  end

  test "the dead render lists the steps before anything has run", %{conn: conn} do
    conn = get(conn, ~p"/system/investors")
    html = html_response(conn, 200)

    assert html =~ ~s(id="investors-reach")
    assert html =~ "This year&#39;s public posts"
    refute html =~ "data-year-reach-total"
  end

  test "works through every step and then shows the year's figure", %{conn: conn} do
    {:ok, view, _html} = mount_card(conn)
    html = render_async(view)

    assert html =~ "data-year-reach-total"

    for key <- Year.steps() do
      assert html =~ ~s(data-year-reach-step="#{key}" data-state="done")
    end

    assert html =~ "Potential reach from reposts"
  end

  test "marks the step in flight while the others wait", %{conn: conn} do
    {:ok, view, _html} = mount_card(conn)
    # Let the view's own run finish first, then stand in for the next run,
    # which has only finished its first step.
    render_async(view)
    send(view.pid, {:year_reach, :started})
    send(view.pid, {:year_reach, {:step, %{key: :posts, ms: 4, count: 1_234}}})
    html = render(view)

    assert html =~ ~s(data-year-reach-step="posts" data-state="done")
    assert html =~ ~s(data-year-reach-step="local_reposts" data-state="running")
    assert html =~ ~s(data-year-reach-step="servers" data-state="waiting")
    assert html =~ "1,234 posts"
    assert html =~ "4 ms"
  end

  test "says so when the run failed", %{conn: conn} do
    {:ok, view, _html} = mount_card(conn)
    render_async(view)
    send(view.pid, {:year_reach, :failed})

    assert render(view) =~ "The calculation failed."
  end

  test "speaks German to a German reader", %{conn: conn} do
    {:ok, view, html} = mount_card(conn, "de")

    assert html =~ "Öffentliche Beiträge dieses Jahres"
    assert render_async(view) =~ "Potenzielle Reichweite durch Reposts"
  end
end
