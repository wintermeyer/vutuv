defmodule VutuvWeb.FeedMarksReadTest do
  @moduledoc """
  When the feed writes the read marker the shell's "Feed" badge counts against
  (`Vutuv.Posts.mark_feed_read/1`).

  Two moments do, and the interesting part of the design is the third one that
  deliberately does not: an arrival that lands while the page is open stays
  unread until the reader reveals it, because until the press those posts are
  behind a pill rather than on screen. The notifications page marks its arrivals
  read on the spot — there the event IS shown as it lands — and copying that here
  would empty the badge for posts nobody ever saw.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Accounts.User
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.Social

  defp followed_author(reader) do
    author = insert(:activated_user)
    Social.follow(reader, author.id)
    author
  end

  # Push the reader's marker into the past, standing in for a visit that started
  # a minute ago: every timestamp here has second precision, so a marker written
  # in this second would swallow the posts these tests create.
  defp read_a_minute_ago(user) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -60)
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [feed_read_at: at])
    %{user | feed_read_at: at}
  end

  defp reload(user), do: Repo.get!(User, user.id)

  test "opening the feed marks it read", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    author = followed_author(user)
    user = read_a_minute_ago(user)
    create_post!(author, %{body: "arrived while you were away"})

    assert Posts.unread_feed_count(user) == 1

    {:ok, _view, _html} = live(conn, ~p"/feed")

    assert Posts.unread_feed_count(reload(user)) == 0
  end

  test "an arrival waiting behind the pill stays unread", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    author = followed_author(user)

    {:ok, view, _html} = live(conn, ~p"/feed")
    user = read_a_minute_ago(user)

    create_post!(author, %{body: "arrived while reading"})
    # Let the arrival through before the test ends: the broadcast is handled in
    # the LiveView's own process, and an unfinished one queries after the test
    # has handed its sandbox connection back.
    assert render(view) =~ "data-show-new"

    # The reader has been told (the pill counts it, right above the timeline) and
    # has not looked, so walking over to a profile now leaves the badge saying
    # so.
    assert Posts.unread_feed_count(reload(user)) == 1
  end

  test "revealing what waited behind the pill marks it read", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    author = followed_author(user)

    {:ok, view, _html} = live(conn, ~p"/feed")
    user = read_a_minute_ago(user)

    create_post!(author, %{body: "arrived while reading"})
    render_click(view, "show-new")

    assert Posts.unread_feed_count(reload(user)) == 0
  end
end
