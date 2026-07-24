defmodule VutuvWeb.NotificationLiveTest do
  # Sync (the ConnCase default): one test injects installation preference
  # defaults into Vutuv.Prefs.Cache, a node-global persistent_term the SQL
  # sandbox does not roll back. Keep it that way.
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Prefs
  alias Vutuv.Prefs.Cache

  # Install `overrides` as the cached installation defaults for one test (the
  # Cache GenServer is off in tests, so put_defaults/1 alone would not show).
  defp with_installation_defaults(overrides) do
    Cache.store(Map.merge(Prefs.shipped_defaults(), overrides))
    on_exit(fn -> Cache.clear() end)
  end

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

    # A brand-new member never chose their handle - vutuv generated it from
    # their name - so the feed tells them what it is and where to change it.
    test "tells a confirmed member their own username", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(live, ~s([data-notification-row][data-kind="username"]))
      assert render(live) =~ "Your automatically assigned vutuv username is"

      # Two links inside the sentence, and the row itself is not one: the
      # handle goes to the member's own profile, the spelled-out URL to the
      # page that changes it.
      assert has_element?(
               live,
               ~s([data-kind="username"] a[href="/#{user.username}"]),
               "@#{user.username}"
             )

      settings_url = VutuvWeb.Endpoint.url() <> "/settings/security"

      assert has_element?(
               live,
               ~s([data-kind="username"] a[href="#{settings_url}"]),
               settings_url
             )
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
               ~s([data-post-preview] a[href="/#{user.username}/posts/#{post.id}"])
             )
    end

    test "a quoted post is formatted like a feed post, not shown as Markdown source", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)

      post =
        insert(:post,
          user: user,
          body: "**Ship it** on Friday\n\n- pack the release\n- write the note"
        )

      :ok = Vutuv.Posts.like_post(insert(:user), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      assert html =~ "<strong>Ship it</strong>"
      assert html =~ "<li>"
      refute html =~ "**Ship it**"
      # The same body recipe the feed uses, so the quote reads like a post.
      assert has_element?(live, ~s([data-post-preview] .markdown.markdown--post))
    end

    test "a @mention in a quoted post links to that member", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # The factory's `user-<n>` handle carries a hyphen, which a real handle
      # never may (`Vutuv.Handles.format/0`) and a mention therefore never
      # matches, so this needs a handle-shaped one.
      colleague = insert(:user, username: "quoted_colleague")

      post = insert(:post, user: user, body: "Thanks @#{colleague.username}!")
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      # The mention keeps its own target, so the quote cannot be one big link:
      # the permalink is a stretched link underneath the body instead.
      assert has_element?(live, ~s([data-post-preview] a[href="/#{colleague.username}"]))
    end

    test "a post that is nothing but an inline image shows no quote", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post = insert(:post, user: user, body: "![a cat](/post_images/cat.jpg)")
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert render(live) =~ "liked your post"
      refute has_element?(live, ~s([data-post-preview]))
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

      assert has_element?(live, ~s([data-reply-preview]), "Neovim, without a doubt.")

      assert has_element?(
               live,
               ~s([data-reply-preview] a[href="/#{replier.username}/posts/#{reply.id}"])
             )
    end

    test "the one-line context above a reply drops the Markdown markers", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      replier = insert(:user)
      parent = insert(:post, user: user, body: "**Which editor** do you swear by?")
      reply = insert(:post, user: replier, body: "Neovim, without a doubt.")

      insert(:post_reply, post: reply, parent_post: parent, parent_author: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      # A breadcrumb stays one plain line (it is inside the row's own link, so
      # it cannot carry links of its own) — but it must not show the markers.
      assert has_element?(live, ~s([data-post-preview]), "Which editor do you swear by?")
      refute html =~ "**Which editor**"
    end

    test "an answer to someone else in my thread renders as a thread row linking the reply", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)

      first_replier = insert(:user)
      other = insert(:user, first_name: "Joe", last_name: "Armstrong")
      root = insert(:post, user: user, body: "The root question")
      {:ok, first} = Vutuv.Posts.create_reply(first_replier, root, %{body: "First answer"})

      {:ok, missed} =
        Vutuv.Posts.create_reply(other, first, %{body: "The answer I used to miss"})

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      assert length(row_ids(html, "thread")) == 1
      assert html =~ "Joe Armstrong"
      assert html =~ "replied in a thread you posted in."

      # The row quotes the reply and links to its permalink. The quote is a
      # formatted block with a stretched link, so the href sits on the inner
      # <a>, not on the element carrying the marker.
      assert has_element?(live, ~s([data-reply-preview]), "The answer I used to miss")

      assert has_element?(
               live,
               ~s([data-reply-preview] a[href="/#{other.username}/posts/#{missed.id}"])
             )
    end

    test "several same-day answers in one thread merge into one thread row", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      root = insert(:post, user: user, body: "The root question")
      {:ok, first} = Vutuv.Posts.create_reply(insert(:user), root, %{body: "First answer"})

      {:ok, _} =
        Vutuv.Posts.create_reply(
          insert(:user, first_name: "Anna", last_name: "Arnold"),
          first,
          %{body: "Second answer"}
        )

      {:ok, _} =
        Vutuv.Posts.create_reply(
          insert(:user, first_name: "Ben", last_name: "Otto"),
          first,
          %{body: "Third answer"}
        )

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      # One grouped row names both answerers; the direct reply row stays its own.
      assert length(row_ids(html, "thread")) == 1
      assert html =~ "Anna Arnold"
      assert html =~ "Ben Otto"
      assert length(row_ids(html, "reply")) == 1
    end

    test "only the day's first thread row carries the opt-out hint (issue #1025)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      # Two separate threads the member rooted, each answered by a third party
      # to the first replier - two distinct thread rows on the same day.
      for body <- ["Thread one", "Thread two"] do
        root = insert(:post, user: user, body: body)
        {:ok, first} = Vutuv.Posts.create_reply(insert(:user), root, %{body: "First answer"})
        {:ok, _} = Vutuv.Posts.create_reply(insert(:user), first, %{body: "Third-party answer"})
      end

      {:ok, live, html} = live(conn, ~p"/notifications")

      assert length(row_ids(html, "thread")) == 2
      # Exactly one hint for the day, linking to the notification settings.
      assert length(Regex.scan(~r/data-thread-hint/, html)) == 1
      assert has_element?(live, ~s([data-thread-hint] a[href="/settings/notifications"]))
      # The link names what it switches off, not a vague "turn this off".
      assert has_element?(
               live,
               ~s([data-thread-hint] a[href="/settings/notifications"]),
               "Turn off thread notifications"
             )
    end

    test "the posts filter tab keeps thread rows", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      root = insert(:post, user: user, body: "The root question")
      {:ok, first} = Vutuv.Posts.create_reply(insert(:user), root, %{body: "First answer"})
      {:ok, _} = Vutuv.Posts.create_reply(insert(:user), first, %{body: "Deeper answer"})

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=posts")

      assert length(row_ids(render(live), "thread")) == 1
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

    test "the post preview keeps only the first five lines by default", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      body = Enum.map_join(1..7, "\n", &"Line #{&1}")
      post = insert(:post, user: user, body: body)
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      assert html =~ "Line 1"
      assert html =~ "Line 5"
      refute html =~ "Line 6"
      # The shipped default needs no inline override: the .notif-clamp
      # stylesheet fallback already says 5.
      assert has_element?(live, ~s([data-post-preview] .notif-clamp))
      refute html =~ "--notif-clamp"
    end

    test "the reader's own line count cuts the quote, server-side and in the CSS clamp", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      {:ok, _user} = Vutuv.Accounts.update_user(user, %{"notification_post_lines" => "2"})

      body = Enum.map_join(1..7, "\n", &"Line #{&1}")
      post = insert(:post, user: user, body: body)
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      assert html =~ "Line 2"
      refute html =~ "Line 3"
      assert html =~ "--notif-clamp:2"
    end

    test "the installation default applies to a member who set no line count", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      with_installation_defaults(%{notification_post_lines: 3})

      body = Enum.map_join(1..7, "\n", &"Line #{&1}")
      post = insert(:post, user: user, body: body)
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      assert html =~ "Line 3"
      refute html =~ "Line 4"
      assert html =~ "--notif-clamp:3"
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

    # Every confirmed account carries its own username welcome note, so an
    # utterly empty feed no longer exists; the empty state now belongs to a
    # filter tab with nothing in it.
    test "shows the empty state for a filter tab with nothing in it", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=posts")

      assert render(live) =~ "Nothing new yet."
      refute has_element?(live, ~s([data-notification-row]))
    end

    test "visiting the page persists the read marker (badge stays cleared)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:follow, follower: insert(:user), followee: user)

      # The follow, plus the account's own username welcome note.
      assert Vutuv.Activity.unread_notification_count(user.id) == 2

      {:ok, _live, _html} = live(conn, ~p"/notifications")

      assert Vutuv.Activity.unread_notification_count(user.id) == 0
    end

    test "events newer than the last visit are marked unread this visit", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      old = insert(:follow, follower: insert(:user), followee: user)
      backdate_follow(old, ~N[2016-11-24 12:00:00])
      # The account's own username welcome note is stamped at its first login,
      # so backdate that too - this test is about the like being the one new
      # thing since the marker.
      backdate_welcome_note(user, ~N[2016-11-24 12:00:00])
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

    test "a short feed is one page and shows no pager", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:follow, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      refute has_element?(live, ~s(nav[aria-label="Pagination"]))
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

  describe "mention rows" do
    test "a post naming the reader renders a mention row linking that post", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = insert(:activated_user, first_name: "Joe", last_name: "Armstrong")

      post =
        create_post!(author, %{body: "Ask @#{user.username} about the schema, they know it."})

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      assert length(row_ids(html, "mention")) == 1
      assert html =~ "Joe Armstrong"
      assert html =~ "mentioned you in a post."

      # The quoted post and the row both open the permalink under the *author*
      # — it is their post, not the reader's, which is what sets this kind
      # apart from a reply or a like.
      assert has_element?(live, ~s([data-post-preview]), "they know it")

      assert has_element?(
               live,
               ~s([data-post-preview] a[href="/#{author.username}/posts/#{post.id}"])
             )
    end

    test "the posts filter tab keeps mention rows", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      create_post!(insert(:activated_user), %{body: "Hello @#{user.username}."})

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=posts")

      assert length(row_ids(render(live), "mention")) == 1
    end
  end

  describe "pagination" do
    # The page size is 50 raw events; a day's followers group into ONE row, so
    # the rows are counted through the grouped row's overflow label ("and N
    # more") rather than by counting <article>s.
    test "a long feed is split into numbered pages the reader can patch between", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      for _ <- 1..102, do: insert(:follow, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      # 3 pages: 50 + 50 + 2.
      assert has_element?(live, ~s(nav[aria-label="Pagination"] a[href="/notifications?page=2"]))
      assert has_element?(live, ~s(nav[aria-label="Pagination"] a[href="/notifications?page=3"]))
      refute has_element?(live, ~s(nav[aria-label="Pagination"] a[href="/notifications?page=4"]))
      # 50 raw events in one grouped row: 2 named + 48 counted.
      assert render(live) =~ "and 48 more"

      live |> element(~s(a[href="/notifications?page=2"])) |> render_click()

      # A page REPLACES the list instead of appending to it: still 50 events.
      assert render(live) =~ "and 48 more"
      assert_patched(live, "/notifications?page=2")

      live |> element(~s(a[href="/notifications?page=3"])) |> render_click()

      # The last page holds the leftover 2 events, so its grouped row names
      # both actors and has no overflow link at all.
      refute render(live) =~ "and 48 more"
      assert has_element?(live, ~s(nav[aria-label="Pagination"] span[aria-current="page"]), "3")
    end

    test "the page is in the URL, so a deep page renders on the static mount too", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      for i <- 1..60 do
        follow = insert(:follow, follower: insert(:user), followee: user)
        backdate_follow(follow, NaiveDateTime.add(~N[2024-01-01 12:00:00], -i))
      end

      body = conn |> get(~p"/notifications?page=2") |> html_response(200)

      # Page 1 holds the account's username welcome note plus the 49 newest
      # follows, so page 2 groups the 11 oldest ones: two named, nine folded.
      assert body =~ "and 9 more"
      assert body =~ ~s(aria-current="page")
      assert body =~ ~s(href="/notifications?page=1")
    end

    test "a page past the end falls back to the first page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      for _ <- 1..60, do: insert(:follow, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications?page=99")

      assert render(live) =~ "and 48 more"
      refute has_element?(live, ~s(nav a[href="/notifications?page=1"]))
    end

    test "paging inside a filter tab keeps the filter", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = insert(:post, user: user)
      for _ <- 1..60, do: :ok = Vutuv.Posts.like_post(insert(:user), post)
      # People events the "posts" tab must leave out of both list and count.
      for _ <- 1..60, do: insert(:follow, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=posts")

      assert has_element?(live, ~s(a[href="/notifications?filter=posts&page=2"]))
      refute has_element?(live, ~s(nav[aria-label="Pagination"] a[href="/notifications?page=2"]))

      live |> element(~s(a[href="/notifications?filter=posts&page=2"])) |> render_click()

      # 60 likes = 50 + 10, so the second page of THIS tab holds 10 likes and
      # none of the 60 followers.
      html = render(live)
      assert html =~ "and 8 more"
      refute html =~ "started following you"
    end

    test "an event arriving live lands on page 1 but never shifts an older page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      for _ <- 1..60, do: insert(:follow, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications?page=2")

      # A real follow, so the event is both broadcast and in the feed's source
      # table: the open page 2 must not take it, page 1 must have it.
      {:ok, _} = Vutuv.Social.follow(insert(:user, first_name: "Grace"), user.id)
      _ = :sys.get_state(live.pid)

      refute render(live) =~ "Grace"

      live |> element(~s(a[href="/notifications?page=1"])) |> render_click()

      assert render(live) =~ "Grace"
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

  defp backdate_welcome_note(%{id: id}, at) do
    import Ecto.Query

    Vutuv.Repo.update_all(
      from(u in Vutuv.Accounts.User, where: u.id == ^id),
      set: [welcome_notified_at: at]
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
