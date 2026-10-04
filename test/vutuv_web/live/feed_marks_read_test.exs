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
  alias Vutuv.Fediverse.Follow
  alias Vutuv.MastodonHelpers
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.ViewerClock

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

  test "a source switch that puts the waiting posts on screen marks it read", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    author = followed_author(user)

    {:ok, view, _html} = live(conn, ~p"/feed")
    user = read_a_minute_ago(user)

    create_post!(author, %{body: "arrived while reading"})
    assert render(view) =~ "data-show-new"

    # What the filter band sends once it has written a source switch. The whole
    # timeline is replaced by a fresh page of the live present, so what stood
    # behind the pill is now at the top of it — shown without a press, and the
    # pill it was counted by is gone. The second way posts reach the reader, and
    # the marker has to move with it or the nav badge keeps promising them.
    send(view.pid, {:filter_band, :changed, reload(user)})

    refute render(view) =~ "data-show-new"
    assert Posts.unread_feed_count(reload(user)) == 0
  end

  # The other direction of the same gate, and the one that would be silent: a
  # travelling reader loads a fresh timeline too, and it clears the pill just as
  # the source switch does — but it is drawing another day, so those posts have
  # been discarded rather than shown. Marking them read here would empty the
  # badge for posts nobody ever saw.
  test "opening a day in the calendar leaves the waiting posts unread", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    author = followed_author(user)

    {:ok, view, _html} = live(conn, ~p"/feed")
    user = read_a_minute_ago(user)

    create_post!(author, %{body: "arrived while reading"})
    assert render(view) =~ "data-show-new"

    yesterday = Date.add(ViewerClock.today(), -1)
    render_click(view, "cal-day", %{"date" => Date.to_iso8601(yesterday)})

    refute render(view) =~ "data-show-new"
    assert Posts.unread_feed_count(reload(user)) == 1
  end

  # The three ways the badge used to be left standing on /feed with no pill
  # beside it — a figure the reader could not press away, because the page had
  # either shown the arrival already or could not find it.
  describe "an arrival the pill does not hold" do
    # A post from another server is ordered by when it was written there and
    # counted by when it reached us. Delivered late, it is not the newest row
    # of its source, so a door asking for "the newest row" found the post
    # already on screen and said nothing while the badge counted the arrival.
    test "a late delivery from another server goes behind the pill", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      account = MastodonHelpers.remote_account()

      Repo.insert!(%Follow{
        user_id: user.id,
        remote_account_id: account.id,
        state: "accepted",
        follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{account.id}"
      })

      now = DateTime.utc_now(:second)
      five_ago = DateTime.add(now, -300)
      MastodonHelpers.cached_post(account, published_at: five_ago, received_at: five_ago)

      {:ok, view, _html} = live(conn, ~p"/feed")
      user = read_a_minute_ago(user)

      late =
        MastodonHelpers.cached_post(account,
          content_text: "Spät zugestellt.",
          published_at: DateTime.add(now, -600),
          received_at: DateTime.utc_now(:second)
        )

      assert Posts.unread_feed_count(reload(user)) == 1

      send(view.pid, {:feed_arrival, %{at: DateTime.to_naive(late.published_at)}})

      assert has_element?(view, "#show-new-posts")
      assert Posts.unread_feed_count(reload(user)) == 1

      render_click(view, "show-new")
      assert Posts.unread_feed_count(reload(user)) == 0
    end

    # A waiting card from another server carries no post of ours, and the three
    # places that look a waiting card up by post id read `.post.id` off every
    # one of them. That took the page down, and the remount marked everything
    # read with the pill gone.
    test "a deleted post leaves a waiting card from another server alone", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = followed_author(user)
      account = MastodonHelpers.remote_account()

      Repo.insert!(%Follow{
        user_id: user.id,
        remote_account_id: account.id,
        state: "accepted",
        follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{account.id}"
      })

      {:ok, view, _html} = live(conn, ~p"/feed")

      remote = MastodonHelpers.cached_post(account)
      send(view.pid, {:feed_arrival, %{at: DateTime.to_naive(remote.published_at)}})
      assert has_element?(view, "#show-new-posts")

      post = create_post!(author, %{body: "gone in a moment"})
      send(view.pid, {:post_deleted, %{post_id: post.id}})

      assert has_element?(view, "#show-new-posts")
    end

    # A repost of a card already on screen folds into that card's avatar stack,
    # in place: shown, with nothing left to reveal.
    test "a repost folded into a card on screen is read", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = followed_author(user)
      reposter = followed_author(user)
      post = create_post!(author, %{body: "already on the page"})

      {:ok, view, _html} = live(conn, ~p"/feed")
      user = read_a_minute_ago(user)

      Posts.repost_post(reposter, post)

      refute render(view) =~ "data-show-new"
      assert Posts.unread_feed_count(reload(user)) == 0
    end

    # "My posts" draws nobody else's writing, so the arrival is neither shown
    # nor offered and the badge is right to keep it. The way back loads the
    # present, and that is the showing.
    test "what arrived under My posts is read on the way back", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = followed_author(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-metric", %{"metric" => "own"})
      user = read_a_minute_ago(user)

      create_post!(author, %{body: "arrived while looking at my own"})

      refute render(view) =~ "data-show-new"
      assert Posts.unread_feed_count(reload(user)) == 1

      render_click(view, "cal-metric", %{"metric" => "feed"})

      assert render(view) =~ "arrived while looking at my own"
      assert Posts.unread_feed_count(reload(user)) == 0
    end
  end
end
