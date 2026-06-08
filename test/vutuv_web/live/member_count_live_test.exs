defmodule VutuvWeb.MemberCountLiveTest do
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  # The application-wide MemberCounter is quiet in tests (its timers are off), so
  # the only `{:member_count, n}` on the topic is the one each test broadcasts.

  test "renders the member-count pill", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, VutuvWeb.MemberCountLive)

    assert html =~ "Number of Members"
    assert has_element?(view, "#member-count")
  end

  test "ticks the displayed total up when the counter broadcasts a new value", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.MemberCountLive)

    Phoenix.PubSub.broadcast(Vutuv.PubSub, "member_count", {:member_count, 60_123})

    # render/1's call is enqueued after the broadcast message, so the handle_info
    # has run by the time it returns — the pill shows the exact, grouped total.
    assert render(view) =~ "60,123"
  end
end
