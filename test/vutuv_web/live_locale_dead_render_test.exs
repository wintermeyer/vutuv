defmodule VutuvWeb.LiveLocaleDeadRenderTest do
  @moduledoc """
  The first paint of a LiveView page is rendered for the member, not for
  nobody.

  The app layout embeds `VutuvWeb.ShellLive` at its top, and on a dead render
  that child mounts in the request process before the page body's own
  expressions run. Its mount resolves no user and used to write the anonymous
  defaults over the plug's answer — so every profile and feed load painted the
  installation's time zone first and the member's own zone only once the
  socket had re-rendered, a 14:00 → 08:00 flip on each page for a member in
  New York. Those children now apply the viewer state on the socket alone
  (`VutuvWeb.LiveLocale.put_viewer/2`); the request process keeps the plug's.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Posts

  # 12:00 UTC on a day two days back — far enough back for the stamp to be the
  # dated form rather than "yesterday". Read in Phoenix, Arizona, which keeps
  # no daylight saving time: 05:00 all year, where a New York expectation
  # would have gone red every November.
  defp noon_utc_two_days_ago do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-2, :day)
    |> Map.merge(%{hour: 12, minute: 0, second: 0, microsecond: {0, 0}})
  end

  defp post_time(html), do: text_of(html, ~s(time[id^="post-time-"]))

  test "the dead render of a profile already shows the member's own time zone", %{conn: conn} do
    {conn, member} = create_and_login_user(conn)
    {:ok, member} = Repo.update(change(member, time_zone: "America/Phoenix"))
    {:ok, post} = Posts.create_post(member, %{body: "a post with a clock on it"})
    {:ok, _} = Repo.update(change(post, inserted_at: noon_utc_two_days_ago()))

    conn = get(conn, ~p"/#{member}")
    dead = post_time(html_response(conn, 200))
    assert dead =~ "05:00", "the first paint showed #{inspect(dead)}, not Phoenix's 05:00"

    # ...and the socket agrees with it, so nothing flips on connect.
    {:ok, _view, live_html} = live(conn)
    assert post_time(live_html) == dead
  end

  test "a socket that mounts for nobody still gets the browser's date shape", %{conn: conn} do
    # The guard must not turn into "never resolve": an anonymous visitor's
    # LiveView process holds nothing when it mounts, and the session's
    # Accept-Language guess is all the shape it will ever get.
    member = insert_activated_user()
    {:ok, post} = Posts.create_post(member, %{body: "a post with a clock on it"})
    {:ok, _} = Repo.update(change(post, inserted_at: noon_utc_two_days_ago()))

    conn = put_req_header(conn, "accept-language", "en-US,en")
    {:ok, _view, html} = live(conn, ~p"/#{member}")
    stamp = post_time(html)

    assert stamp =~ ~r/^\d{1,2}\/\d{1,2}\/\d{2}, /,
           "expected the US date shape, got #{inspect(stamp)}"
  end
end
