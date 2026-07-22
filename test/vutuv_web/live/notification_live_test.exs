defmodule VutuvWeb.NotificationLiveTest do
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "GET /notifications" do
    test "renders the first page in the static HTTP response (issue #919 snappy first paint)", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      follower = insert(:user, first_name: "Grace", last_name: "Hopper")
      insert(:follow, follower: follower, followee: user)

      # A plain HTTP GET is what the browser paints *before* the LiveView socket
      # connects. The notifications must already be in that first render, not
      # arrive a websocket round trip later (issue #919).
      conn = get(conn, ~p"/notifications")
      body = html_response(conn, 200)

      assert body =~ "Grace Hopper"
      assert body =~ "started following you"
      assert body =~ ~s(data-notification-row)
    end

    test "lists real events derived from the database", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      follower = insert(:user, first_name: "Grace", last_name: "Hopper")
      insert(:follow, follower: follower, followee: user)

      endorser = insert(:user, first_name: "Ada", last_name: "Lovelace")
      tag = insert(:tag, name: "Phoenix")
      user_tag = insert(:user_tag, user: user, tag: tag)
      insert(:user_tag_endorsement, user: endorser, user_tag: user_tag)

      {:ok, live, html} = live(conn, ~p"/notifications")

      assert html =~ "Notifications"
      assert html =~ "Grace Hopper"
      assert html =~ "started following you"

      assert render(live) =~ "endorsed you for Phoenix"
      assert has_element?(live, ~s([data-notification-row][data-kind="follower"]))

      # The actor's name links to their profile.
      assert render(live) =~ ~s(href="/#{follower.username}")
    end

    test "the row timestamp is a machine-readable UTC <time> showing Berlin clock time", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      insert(:follow, follower: insert(:user, first_name: "Grace"), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      # Sections are Berlin calendar days (the site's canonical clock, like
      # post times), so the row shows a server-rendered Berlin HH:MM while the
      # <time> keeps an unambiguous ISO-8601 UTC datetime for machines.
      assert render(live) =~ ~r/<time[^>]*datetime="\d{4}-\d{2}-\d{2}T[^"]*Z"/
    end

    test "a derived row shows the actor's real avatar when they have one", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      follower =
        insert(:user, first_name: "Grace", last_name: "Hopper", avatar: "grace.jpg")

      insert(:follow, follower: follower, followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      # The real photo URL, not the inline default-avatar SVG.
      assert render(live) =~ ~s(/avatars/#{follower.id}/)
    end

    test "the actor's avatar carries the online-presence dot keyed by their id", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      follower =
        insert(:user, first_name: "Grace", last_name: "Hopper", avatar: "grace.jpg")

      insert(:follow, follower: follower, followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(live, ~s([data-presence-user-id="#{follower.id}"]))
    end

    test "a picture-less actor still gets the presence dot on the kind glyph", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      follower = insert(:user, first_name: "Ada", last_name: "Lovelace")
      insert(:follow, follower: follower, followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(live, ~s([data-presence-user-id="#{follower.id}"]))
      refute render(live) =~ ~s(/avatars/#{follower.id}/)
    end

    test "shows a mutual follow as a connection event with the handshake glyph", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      other = insert(:user, first_name: "Wojtek", last_name: "Mach")
      connect!(user, other)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert render(live) =~ "is now connected with you"
      assert render(live) =~ "🤝"
    end

    test "a same-day mutual follow shows only the connection row, not a follower double", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)

      # The mutual follow derives both a follower and a connection event with
      # the same actor on the same day; "is now connected" implies "follows
      # you", so the follower row would be redundant noise.
      connect!(user, insert(:user, first_name: "Wojtek", last_name: "Mach"))
      # An unrelated one-way follower on the same day still shows.
      insert(:follow, follower: insert(:user, first_name: "Grace"), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      assert length(row_ids(html, "connection")) == 1
      assert [_] = row_ids(html, "follower")
      # The follower row names Grace, not the already-connected Wojtek.
      assert has_element?(live, ~s([data-notification-row][data-kind="follower"]), "Grace")
      refute has_element?(live, ~s([data-notification-row][data-kind="follower"]), "Wojtek")
    end

    test "a reply notification links to the parent post's thread", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      parent = insert(:post, user: user)
      insert(:post_reply, post: insert(:post), parent_post: parent, parent_author: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert render(live) =~ ~s(href="/#{user.username}/posts/#{parent.id}")
    end

    test "a like is shown and links to the liked post", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post = insert(:post, user: user)
      fan = insert(:user, first_name: "Fanny", last_name: "First")
      :ok = Vutuv.Posts.like_post(fan, post)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      assert html =~ "liked your post"
      assert html =~ ~s(href="/#{user.username}/posts/#{post.id}")
    end

    test "a like notification previews the liked post's body", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post = insert(:post, user: user, body: "Ship the redesign on Friday")
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(live, ~s([data-post-preview]), "Ship the redesign on Friday")

      assert has_element?(
               live,
               ~s([data-post-preview][href="/#{user.username}/posts/#{post.id}"])
             )
    end

    test "two likes of the same post on the same day merge into one row", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post = insert(:post, user: user, body: "Grouped post body")
      :ok = Vutuv.Posts.like_post(insert(:user, first_name: "Anna", last_name: "Arnold"), post)
      :ok = Vutuv.Posts.like_post(insert(:user, first_name: "Ben", last_name: "Otto"), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      # One row names both likers; the post is quoted once, not per like.
      assert length(row_ids(html, "like")) == 1
      assert html =~ "Anna Arnold"
      assert html =~ "Ben Otto"
      assert length(String.split(html, "Grouped post body")) - 1 == 1
    end

    test "likes of different posts stay separate rows", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      :ok = Vutuv.Posts.like_post(insert(:user), insert(:post, user: user, body: "First post"))
      :ok = Vutuv.Posts.like_post(insert(:user), insert(:post, user: user, body: "Second post"))

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert length(row_ids(render(live), "like")) == 2
    end

    test "several followers on one day merge into one row with an overflow link", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      insert(:follow,
        follower: insert(:user, first_name: "Anna", last_name: "Arnold"),
        followee: user
      )

      insert(:follow,
        follower: insert(:user, first_name: "Ben", last_name: "Otto"),
        followee: user
      )

      insert(:follow,
        follower: insert(:user, first_name: "Cara", last_name: "Prima"),
        followee: user
      )

      insert(:follow,
        follower: insert(:user, first_name: "Dora", last_name: "Quarta"),
        followee: user
      )

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      # One grouped row: two names spelled out, the rest counted, plural verb.
      assert length(row_ids(html, "follower")) == 1
      assert html =~ "and 2 more"
      assert html =~ "are now following you."
      # The overflow leads to the member's own followers list.
      assert has_element?(live, ~s(a[href="/#{user.username}/followers"]), "and 2 more")
    end

    test "one endorser's same-day endorsements merge into one row naming every tag", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)

      endorser = insert(:user, first_name: "Ada", last_name: "Lovelace")

      for tag_name <- ["Elixir", "Phoenix"] do
        user_tag = insert(:user_tag, user: user, tag: insert(:tag, name: tag_name))
        insert(:user_tag_endorsement, user: endorser, user_tag: user_tag)
      end

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      assert length(row_ids(html, "endorsement")) == 1
      assert html =~ "endorsed you for Elixir and Phoenix."
    end

    test "different endorsers stay separate rows", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      for _ <- 1..2 do
        user_tag = insert(:user_tag, user: user, tag: insert(:tag))
        insert(:user_tag_endorsement, user: insert(:user), user_tag: user_tag)
      end

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert length(row_ids(render(live), "endorsement")) == 2
    end

    test "rows sit under Berlin-day section headings", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      # One event today, one on a fixed historic day.
      insert(:follow, follower: insert(:user), followee: user)
      old = insert(:follow, follower: insert(:user), followee: user)
      backdate_follow(old, ~N[2016-11-24 12:00:00])

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      assert html =~ "Today"
      assert html =~ "November 24, 2016"
    end

    test "a reply notification previews both the parent post and the reply", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      replier = insert(:user)
      parent = insert(:post, user: user, body: "Which editor do you swear by?")
      reply = insert(:post, user: replier, body: "Neovim, without a doubt.")

      insert(:post_reply, post: reply, parent_post: parent, parent_author: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(
               live,
               ~s([data-post-preview][href="/#{user.username}/posts/#{parent.id}"]),
               "Which editor do you swear by?"
             )

      assert has_element?(
               live,
               ~s([data-reply-preview][href="/#{replier.username}/posts/#{reply.id}"]),
               "Neovim, without a doubt."
             )
    end

    test "a reply hidden from the recipient is not quoted", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      replier = insert(:user)
      parent = insert(:post, user: user, body: "Public question")
      reply = insert(:post, user: replier, body: "Secret answer")
      Vutuv.Repo.insert!(%Vutuv.Posts.PostDenial{post_id: reply.id, denied_user_id: user.id})

      insert(:post_reply, post: reply, parent_post: parent, parent_author: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert render(live) =~ "Public question"
      refute render(live) =~ "Secret answer"
      refute has_element?(live, ~s([data-reply-preview]))
    end

    test "the post preview keeps only the first three lines", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      body = "Line one\nLine two\nLine three\nLine four is hidden"
      post = insert(:post, user: user, body: body)
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      assert html =~ "Line one"
      assert html =~ "Line three"
      refute html =~ "Line four is hidden"
    end

    test "a like on a bodyless (photo-only) post shows no preview", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post = insert(:post, user: user, body: "")
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert render(live) =~ "liked your post"
      refute has_element?(live, ~s([data-post-preview]))
    end

    test "non-post notifications carry no preview", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:follow, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert render(live) =~ "started following you"
      refute has_element?(live, ~s([data-post-preview]))
    end

    test "a like arriving live carries its post preview", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = insert(:post, user: user, body: "Live-quoted post body")

      {:ok, live, _html} = live(conn, ~p"/notifications")

      fan = insert(:user, first_name: "Fanny", last_name: "First")
      Vutuv.Activity.notify_like(user.id, fan, post.id)
      _ = :sys.get_state(live.pid)

      assert has_element?(live, ~s([data-post-preview]), "Live-quoted post body")
    end

    test "a live like merges into the derived same-day row for the same post", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post = insert(:post, user: user, body: "Merged live post")
      :ok = Vutuv.Posts.like_post(insert(:user, first_name: "Anna", last_name: "Arnold"), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      assert length(row_ids(render(live), "like")) == 1

      fan = insert(:user, first_name: "Fanny", last_name: "First")
      Vutuv.Activity.notify_like(user.id, fan, post.id)
      _ = :sys.get_state(live.pid)

      html = render(live)
      # Still one row for the post - now naming both likers.
      assert length(row_ids(html, "like")) == 1
      assert html =~ "Anna Arnold"
      assert html =~ "Fanny First"
    end

    test "kind labels render as human text, not raw kind strings", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      connect!(user, insert(:user))

      {:ok, live, _html} = live(conn, ~p"/notifications")

      refute render(live) =~ ">connection<"
      assert render(live) =~ "Connection"
    end

    test "shows a reply as a reply event, but not a self-reply", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      replier = insert(:user, first_name: "Joe", last_name: "Armstrong")
      parent = insert(:post, user: user)

      insert(:post_reply,
        post: insert(:post, user: replier),
        parent_post: parent,
        parent_author: user
      )

      insert(:post_reply,
        post: insert(:post, user: user),
        parent_post: parent,
        parent_author: user
      )

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert render(live) =~ "replied to your post"
      assert render(live) =~ "Joe Armstrong"
      # The self-reply derives no row.
      assert length(row_ids(render(live), "reply")) == 1
    end

    test "shows the empty state when nothing happened yet", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert render(live) =~ "Nothing new yet."
      refute has_element?(live, ~s([data-notification-row]))
    end

    test "visiting the page persists the read marker (badge stays cleared)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:follow, follower: insert(:user), followee: user)

      assert Vutuv.Activity.unread_notification_count(user.id) == 1

      {:ok, _live, _html} = live(conn, ~p"/notifications")

      assert Vutuv.Activity.unread_notification_count(user.id) == 0
    end

    test "events newer than the last visit are marked unread this visit", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      old = insert(:follow, follower: insert(:user), followee: user)
      backdate_follow(old, ~N[2016-11-24 12:00:00])
      # Reading back then leaves today's like unseen.
      set_read_marker(user, ~N[2016-11-25 00:00:00])

      post = insert(:post, user: user)
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      # The fresh like is highlighted, the long-seen follower row is not.
      assert has_element?(live, ~s([data-notification-row][data-kind="like"][data-unread]))
      refute has_element?(live, ~s([data-notification-row][data-kind="follower"][data-unread]))
      # The header counts what is new since the last visit.
      assert html =~ "1 new notification"
      # And the visit still clears the badge for next time.
      assert Vutuv.Activity.unread_notification_count(user.id) == 0
    end

    test "redirects a logged-out visitor to the login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/notifications")
    end

    test "renders in German for a German browser (locale is a test dimension)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      for _ <- 1..3, do: insert(:follow, follower: insert(:user), followee: user)

      body =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/notifications")
        |> html_response(200)

      assert body =~ "Mitteilungen"
      assert body =~ "Heute"
      # The grouped plural sentence and the folded overflow, both German.
      assert body =~ "folgen Ihnen jetzt."
      assert body =~ "und 1 weitere"
    end

    test "a new follower appears live without a reload", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/notifications")

      Vutuv.Activity.notify_new_follower(user.id, %{first_name: "Ada", last_name: "Lovelace"})
      _ = :sys.get_state(live.pid)

      html = render(live)
      assert html =~ "Ada Lovelace"
      assert html =~ "started following you."
    end

    test "a live event while on the page re-marks read so the shell badge stays 0", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/notifications")

      Vutuv.Activity.subscribe(user.id)

      follower = insert(:user, first_name: "Ada", last_name: "Lovelace")
      insert(:follow, follower: follower, followee: user)
      Vutuv.Activity.notify_new_follower(user.id, follower)
      _ = :sys.get_state(live.pid)

      assert_receive :notifications_read
      assert Vutuv.Activity.unread_notification_count(user.id) == 0
    end

    test "a long feed offers a numbered Load more, which appends the older events", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      # Two more than two page sizes, all in the same second - the grouped
      # follower row swallows them, so count raw actors via the overflow label.
      for _ <- 1..102, do: insert(:follow, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      # The label says what the next click loads and how much is left in total.
      assert live |> element("#load-more") |> render() =~ "Load 50 of 52 more"
      # 50 raw events in one grouped row: 2 named + 48 counted.
      assert render(live) =~ "and 48 more"

      live |> element("#load-more") |> render_click()

      assert render(live) =~ "and 98 more"
      assert live |> element("#load-more") |> render() =~ "Load 2 of 2 more"

      live |> element("#load-more") |> render_click()

      assert render(live) =~ "and 100 more"
      refute has_element?(live, "#load-more")
    end

    test "the Load more label falls back to plain text when the snapshot runs out", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      for i <- 1..51 do
        c = insert(:follow, follower: insert(:user), followee: user)
        backdate_follow(c, NaiveDateTime.add(~N[2024-01-01 12:00:00], -i))
      end

      {:ok, live, _html} = live(conn, ~p"/notifications")
      assert live |> element("#load-more") |> render() =~ "Load 1 of 1 more"

      for i <- 1..60 do
        c = insert(:follow, follower: insert(:user), followee: user)
        backdate_follow(c, NaiveDateTime.add(~N[2024-01-01 12:00:00], -100 - i))
      end

      live |> element("#load-more") |> render_click()

      assert has_element?(live, "#load-more")
      label = live |> element("#load-more") |> render()
      refute label =~ "0 of 0"
      assert label =~ "Load more"
    end

    test "a short feed shows no Load more button", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:follow, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      refute has_element?(live, "#load-more")
    end

    test "a real follower is rendered with a profile link and avatar", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/notifications")

      follower = insert(:user, first_name: "Grace", last_name: "Hopper")

      Vutuv.Activity.notify_new_follower(user.id, follower)
      _ = :sys.get_state(live.pid)

      html = render(live)
      assert html =~ "Grace Hopper"
      assert html =~ ~s(href="/#{follower.username}")
    end
  end

  describe "filter tabs" do
    test "?filter=posts keeps replies and likes, drops people events", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      insert(:follow, follower: insert(:user, first_name: "Grace"), followee: user)
      post = insert(:post, user: user, body: "Filterable post")
      :ok = Vutuv.Posts.like_post(insert(:user, first_name: "Fanny"), post)

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=posts")

      html = render(live)
      assert html =~ "liked your post"
      refute html =~ "started following you"
    end

    test "?filter=people keeps follower events, drops post events", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      insert(:follow, follower: insert(:user, first_name: "Grace"), followee: user)
      post = insert(:post, user: user, body: "Filterable post")
      :ok = Vutuv.Posts.like_post(insert(:user, first_name: "Fanny"), post)

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=people")

      html = render(live)
      assert html =~ "started following you"
      refute html =~ "liked your post"
    end

    test "the tabs patch the filter without a reload", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:follow, follower: insert(:user, first_name: "Grace"), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      assert has_element?(live, ~s([data-notif-filter-tab="all"][aria-current="page"]))

      live
      |> element(~s([data-notif-filter-tab="posts"]))
      |> render_click()

      assert_patch(live, ~p"/notifications?filter=posts")
      refute render(live) =~ "started following you"
    end

    test "a live event outside the active filter is not shown", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = insert(:post, user: user, body: "Filtered live post")

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=people")

      Vutuv.Activity.notify_like(user.id, insert(:user, first_name: "Fanny"), post.id)
      _ = :sys.get_state(live.pid)

      refute render(live) =~ "liked your post"
    end
  end

  describe "the desktop rail" do
    test "suggests following back a recent follower and follows on click", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      follower = insert(:user, first_name: "Grace", last_name: "Hopper")
      insert(:follow, follower: follower, followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(live, "#follow-back", "Grace Hopper")

      live
      |> element(~s(#follow-back button[phx-value-followee="#{follower.id}"]))
      |> render_click()

      # The follow is real and the suggestion disappears.
      assert Vutuv.Social.user_follows_user?(user.id, follower.id)
      refute has_element?(live, "#follow-back", "Grace Hopper")
    end

    test "shows no follow-back card when every follower is followed back", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      connect!(user, insert(:user))

      {:ok, live, _html} = live(conn, ~p"/notifications")

      refute has_element?(live, "#follow-back")
    end

    test "summarizes the last 30 days of activity", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:follow, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(live, "#activity-summary", "Follower")
    end

    test "shows no summary card when the window is empty", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      old = insert(:follow, follower: insert(:user), followee: user)
      backdate_follow(old, ~N[2016-11-24 12:00:00])

      {:ok, live, _html} = live(conn, ~p"/notifications")

      refute has_element?(live, "#activity-summary")
    end
  end

  describe "midnight day-change refresh" do
    test "a :day_changed tick re-renders the sections without dropping them", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = insert(:post, user: user, body: "Ship the redesign on Friday")
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      assert has_element?(live, ~s([data-post-preview]), "Ship the redesign on Friday")

      send(live.pid, :day_changed)
      _ = :sys.get_state(live.pid)
      assert has_element?(live, ~s([data-post-preview]), "Ship the redesign on Friday")
    end
  end

  # Grouped rows carry `id="notification-<kind>-..."` plus a data-kind marker.
  defp row_ids(html, kind) do
    Regex.scan(~r/data-kind="#{kind}"/, html)
  end

  defp backdate_follow(%Vutuv.Social.Follow{id: id}, at) do
    import Ecto.Query

    Vutuv.Repo.update_all(
      from(c in Vutuv.Social.Follow, where: c.id == ^id),
      set: [inserted_at: at]
    )
  end

  defp set_read_marker(user, at) do
    import Ecto.Query

    Vutuv.Repo.update_all(
      from(u in Vutuv.Accounts.User, where: u.id == ^user.id),
      set: [notifications_read_at: at]
    )
  end
end
