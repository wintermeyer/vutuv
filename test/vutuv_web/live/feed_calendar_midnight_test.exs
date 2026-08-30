defmodule VutuvWeb.FeedCalendarMidnightTest do
  @moduledoc """
  The reader's day rolling over under a page that is already open.

  `Vutuv.DayClock` broadcasts on every whole UTC hour, which is when somebody's
  midnight falls, and the feed has listened to it for as long as post stamps
  have said "Gestern". The calendar did not: it read the clock inside the card,
  where only a render can refresh it and nothing asks for one at midnight. What
  that cost was not merely a stale date — the new day's own cell stayed greyed
  out as a future day, so the reader could not click their way into the day they
  were in.

  `async: false`, and its own file: these tests move `:viewer_clock_now`, which
  is application env the SQL sandbox does not roll back and **every** timestamp
  in the app reads (`Vutuv.ViewerClock.today/0`, so post stamps and the
  notifications sections too). A concurrent test would see the moved clock.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.PostsHelpers
  alias Vutuv.Social
  alias Vutuv.ViewerClock

  defp feed_with_history(viewer) do
    author = insert(:activated_user)
    Social.follow(viewer, author.id)

    post = PostsHelpers.create_post!(author, %{body: "from this morning"})
    PostsHelpers.backdate_post!(post, 3_600)

    author
  end

  # Moves the clock every calendar day in the app is read off, and puts it back.
  #
  # `fetch_env/2` and not `get_env/2`: the latter answers `nil` both for
  # "absent" and for "holds nil", so a naive restore writes `nil` back as a real
  # value and every later reader gets it instead of the real clock.
  defp travel_to(%DateTime{} = at) do
    original = Application.fetch_env(:vutuv, :viewer_clock_now)
    Application.put_env(:vutuv, :viewer_clock_now, at)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, :viewer_clock_now, was)
        :error -> Application.delete_env(:vutuv, :viewer_clock_now)
      end
    end)
  end

  defp tick(view) do
    send(view.pid, :day_changed)
    render(view)
  end

  defp calendar(view), do: render(element(view, "#feed-calendar-rail"))
  defp iso(date), do: Date.to_iso8601(date)

  describe "the day rolls over under an open page" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      today = ViewerClock.today()
      %{conn: conn, today: today, tomorrow: Date.add(today, 1)}
    end

    test "the folded card takes the new date", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/feed")

      assert calendar(view) =~ ViewerClock.format(ctx.today, :date)

      travel_to(DateTime.add(DateTime.utc_now(), 1, :day))
      tick(view)

      assert calendar(view) =~ ViewerClock.format(ctx.tomorrow, :date)
      refute calendar(view) =~ ViewerClock.format(ctx.today, :date)
    end

    test "the new day stops being a future day nobody may click", ctx do
      # The one that is not merely cosmetic: the grid refuses a day it reads as
      # future, so before the rollover reached the card the reader was locked
      # out of the very day they were in.
      {:ok, view, _html} = live(ctx.conn, ~p"/feed")
      render_click(view, "cal-toggle")

      assert has_element?(view, ~s([phx-value-date="#{iso(ctx.tomorrow)}"][disabled]))

      travel_to(DateTime.add(DateTime.utc_now(), 1, :day))
      tick(view)

      refute has_element?(view, ~s([phx-value-date="#{iso(ctx.tomorrow)}"][disabled]))
    end

    test "the today ring moves with it", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/feed")
      render_click(view, "cal-toggle")

      assert has_element?(view, ~s([phx-value-date="#{iso(ctx.today)}"].ring-slate-400))

      travel_to(DateTime.add(DateTime.utc_now(), 1, :day))
      tick(view)

      assert has_element?(view, ~s([phx-value-date="#{iso(ctx.tomorrow)}"].ring-slate-400))
      refute has_element?(view, ~s([phx-value-date="#{iso(ctx.today)}"].ring-slate-400))
    end
  end
end
