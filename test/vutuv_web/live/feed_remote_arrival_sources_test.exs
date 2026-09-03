defmodule VutuvWeb.FeedRemoteArrivalSourcesTest do
  @moduledoc """
  What an open feed does with the announcement that something from the other
  network arrived.

  `Vutuv.Fediverse.nudge_feeds/2` deliberately carries no id — only the
  reader's own sources know whether that write reaches *them* — so the message
  says "look" and the feed asks. Which sources it asks is the whole subject of
  this file: it used to ask a hard-wired `:fediverse`, while the nudge is sent
  for **four** kinds of write, two of which are vutuv-tab entries
  (`feed_remote_boosts(only: :local)` and the two reshare sources). The feed
  looked in the wrong place, found nothing, and said nothing — no pill, no
  card, no error, until the next page load.

  So each test drives one of the four and asks for the pill. The two that were
  broken are marked; keep all four, because the pair that worked is what stops
  a future narrowing of the source list from passing.

  Not async: the reshare claims from `Vutuv.RateLimiter`, a shared ETS table
  the SQL sandbox does not roll back.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.PostBoost
  alias Vutuv.MastodonHelpers
  alias Vutuv.Posts
  alias Vutuv.Social

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp reader(conn) do
    {conn, user} = create_and_login_user(conn)
    {conn, user}
  end

  # The reader following an account out there, which is what makes that
  # account's own posts and its boosts reach them at all.
  defp follow_remote!(user, account) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{account.id}"
    })
  end

  # The announcement itself, in the shape `nudge_feeds/2` really broadcasts:
  # naive UTC, and no id.
  defp announce(view, %DateTime{} = at), do: announce(view, DateTime.to_naive(at))

  defp announce(view, %NaiveDateTime{} = at) do
    send(view.pid, {:remote_feed_arrival, %{at: at}})
    render(view)
  end

  describe "a followed account's own post" do
    test "fills the pill", %{conn: conn} do
      {conn, user} = reader(conn)
      account = MastodonHelpers.remote_account()
      follow_remote!(user, account)

      {:ok, view, _html} = live(conn, ~p"/feed")

      post = MastodonHelpers.cached_post(account, content_text: "Direkt von dort.")
      announce(view, post.published_at)

      assert has_element?(view, "#show-new-posts")
    end
  end

  describe "a followed account boosting a stranger's post" do
    test "fills the pill", %{conn: conn} do
      {conn, user} = reader(conn)
      booster = MastodonHelpers.remote_account()
      follow_remote!(user, booster)

      {:ok, view, _html} = live(conn, ~p"/feed")

      post = MastodonHelpers.cached_post(MastodonHelpers.remote_account())

      boost =
        Repo.insert!(%PostBoost{
          remote_account_id: booster.id,
          remote_post_id: post.id,
          activity_id: "https://social.example/act/#{System.unique_integer([:positive])}",
          announced_at: DateTime.utc_now(:second)
        })

      announce(view, boost.announced_at)

      assert has_element?(view, "#show-new-posts")
    end
  end

  describe "a followed account boosting a MEMBER's post" do
    # Broken until this file: the boost of a member's post is
    # `feed_remote_boosts(only: :local)`, a vutuv-tab source, so a door asking
    # `:fediverse` never found it. `nudge_boost_feeds/4`'s own comment says this
    # is a vutuv-tab entry — the door did not know.
    setup %{conn: conn} do
      {conn, user} = reader(conn)

      # The author is deliberately **not** followed: the boost is the only
      # reason this post could reach the reader, which is the whole point of
      # issue #1167 ("how members get discovered through the outside network").
      # Following the author instead would put the post on screen before the
      # boost lands, and then silence is the right answer — that is the
      # one-card-per-subject rule from #1970, not this gap.
      author = insert(:activated_user)
      {:ok, post} = Posts.create_post(author, %{body: "Ein Beitrag von hier."})

      booster = MastodonHelpers.remote_account()
      follow_remote!(user, booster)

      %{conn: conn, user: user, post: post, booster: booster}
    end

    test "fills the pill on the All tab", %{conn: conn, post: post, booster: booster} do
      {:ok, view, _html} = live(conn, ~p"/feed")

      boost = MastodonHelpers.boost(booster, post)
      announce(view, boost.announced_at)

      assert has_element?(view, "#show-new-posts")
    end

    test "and on the vutuv half of the band, which is where it belongs", %{
      conn: conn,
      post: post,
      booster: booster,
      user: user
    } do
      # The band's own state, written the way the band writes it and read back
      # at mount (`Posts.remembered_feed_filter/1`) — the source switch is a
      # stored member setting, not a control on this LiveView.
      :ok = Posts.remember_feed_filter(user, :vutuv, :all)

      {:ok, view, _html} = live(conn, ~p"/feed")

      boost = MastodonHelpers.boost(booster, post)
      announce(view, boost.announced_at)

      assert has_element?(view, "#show-new-posts")
    end
  end

  describe "a member here resharing a post from the other network" do
    # Broken until this file, the same way: `feed_remote_reposts` is a vutuv-tab
    # source. This one drives the real write, so the broadcast is the app's own
    # rather than a hand-sent message.
    test "fills the pill", %{conn: conn} do
      {conn, user} = reader(conn)

      resharer = MastodonHelpers.federating_member()
      Social.follow(user, resharer.id)

      post = MastodonHelpers.cached_post(MastodonHelpers.remote_account())

      {:ok, view, _html} = live(conn, ~p"/feed")

      {:ok, :reposted} = Fediverse.repost_remote_post(resharer, post)

      assert has_element?(view, "#show-new-posts")
    end
  end
end
