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
    # their name - so the first thing they ever read from us greets them, says
    # what the handle is and where to change it, and offers the LinkedIn import
    # while an existing profile is still on their mind.
    test "tells a confirmed member their own username", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(live, ~s([data-notification-row][data-kind="username"]))
      html = render(live)
      assert html =~ "Welcome to vutuv!"
      # It greets before it explains: leading with the machine detail ("Your
      # automatically assigned vutuv username is …") is what this replaced.
      refute html =~ "Your automatically assigned"

      # Three links inside the sentence, and the row itself is not one: the
      # handle goes to the member's own profile, the spelled-out URLs to the
      # page that changes it and to the LinkedIn import.
      assert has_element?(
               live,
               ~s([data-kind="username"] a[href="/#{user.username}"]),
               "@#{user.username}"
             )

      # The rename form lives on its own page (/settings/username); the
      # security page holds sign-in credentials and cannot change a handle.
      settings_url = VutuvWeb.Endpoint.url() <> "/settings/username"

      assert has_element?(
               live,
               ~s([data-kind="username"] a[href="#{settings_url}"]),
               settings_url
             )

      # The import offer is the reason this row mentions LinkedIn at all; the
      # page is otherwise buried in /settings and nobody goes looking for it.
      import_url = VutuvWeb.Endpoint.url() <> "/settings/import/linkedin"

      assert has_element?(
               live,
               ~s([data-kind="username"] a[href="#{import_url}"]),
               import_url
             )

      # The sentence must not END on a URL: the full stop then sits flush
      # against the address and reads as part of it (reported 2026-08-04). This
      # catches it whichever wording or language the row is in, because it looks
      # for the punctuation right after the closing tag rather than for a phrase.
      refute html =~ "/settings/import/linkedin</a>."
      refute html =~ "/settings/username</a>."
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

      # Both people events sit as lines inside the day's one people card.
      assert has_element?(
               live,
               ~s([data-notification-row][data-kind="people"] [data-event-kind="follower"])
             )

      assert has_element?(
               live,
               ~s([data-notification-row][data-kind="people"] [data-event-kind="endorsement"])
             )

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

    test "a people card shows the actor's real avatar when they have one", %{conn: conn} do
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

    test "a picture-less actor still gets the presence dot", %{conn: conn} do
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

    test "a same-day mutual follow shows only the connection line, not a follower double", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)

      # The mutual follow derives both a follower and a connection event with
      # the same actor on the same day; "is now connected" implies "follows
      # you", so the follower line would be redundant noise.
      connect!(user, insert(:user, first_name: "Wojtek", last_name: "Mach"))
      # An unrelated one-way follower on the same day still shows.
      insert(:follow, follower: insert(:user, first_name: "Grace"), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      assert length(lines(html, "connection")) == 1
      assert [_] = lines(html, "follower")
      # The follower line names Grace, not the already-connected Wojtek.
      assert has_element?(live, ~s([data-event-kind="follower"]), "Grace")
      refute has_element?(live, ~s([data-event-kind="follower"]), "Wojtek")
    end

    test "the people card's head counts the day's people events", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      connect!(user, insert(:user, first_name: "Wojtek"))
      insert(:follow, follower: insert(:user, first_name: "Grace"), followee: user)
      insert(:follow, follower: insert(:user, first_name: "Ada"), followee: user)
      user_tag = insert(:user_tag, user: user, tag: insert(:tag, name: "Elixir"))
      insert(:user_tag_endorsement, user: insert(:user), user_tag: user_tag)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      # One card for the day's people, and its head is the tally: the reader
      # knows what happened before reading a single line.
      assert length(rows(render(live), "people")) == 1
      assert has_element?(live, ~s([data-kind="people"] [data-card-title]), "1 new connection")
      assert has_element?(live, ~s([data-kind="people"] [data-card-title]), "2 new followers")
      assert has_element?(live, ~s([data-kind="people"] [data-card-title]), "1 endorsement")
    end

    test "a reply card is headed by the parent post and opens its thread", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      parent = insert(:post, user: user, body: "Which editor do you swear by?")
      insert(:post_reply, post: insert(:post), parent_post: parent, parent_author: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(
               live,
               ~s([data-post-card][href="/#{user.username}/posts/#{parent.id}"]),
               "Which editor do you swear by?"
             )

      # The head says whose post this is: the reader's own.
      assert has_element?(live, ~s([data-kind="post"] [data-card-eyebrow]), "Your post")
    end

    test "a like is a line under the liked post's card", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post = insert(:post, user: user)
      fan = insert(:user, first_name: "Fanny", last_name: "First")
      :ok = Vutuv.Posts.like_post(fan, post)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      # The card's head already names the post, so the line only says who and
      # what.
      assert html =~ "Fanny First"
      assert has_element?(live, ~s([data-event-kind="like"]), "likes this.")
      assert html =~ ~s(href="/#{user.username}/posts/#{post.id}")
    end

    test "the card head quotes the liked post's body as a plain two-line teaser", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post =
        insert(:post,
          user: user,
          body: "**Ship it** on Friday\n\n- pack the release\n- write the note"
        )

      :ok = Vutuv.Posts.like_post(insert(:user), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      # Plain text: no Markdown markers, no rendered markup — the formatted
      # quote belongs to a reply line, which the reader opens on purpose.
      assert has_element?(live, ~s([data-post-card]), "Ship it on Friday")
      refute html =~ "**Ship it**"
      refute has_element?(live, ~s([data-post-preview]))

      assert has_element?(
               live,
               ~s([data-post-card][href="/#{user.username}/posts/#{post.id}"])
             )
    end

    test "a post that is nothing but an inline image is named as textless", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post = insert(:post, user: user, body: "![a cat](/post_images/cat.jpg)")
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert render(live) =~ "likes this."
      assert has_element?(live, ~s([data-post-card-textless]), "Post without text")
    end

    test "two likes of the same post on the same day merge into one line of one card", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)

      post = insert(:post, user: user, body: "Grouped post body")
      :ok = Vutuv.Posts.like_post(insert(:user, first_name: "Anna", last_name: "Arnold"), post)
      :ok = Vutuv.Posts.like_post(insert(:user, first_name: "Ben", last_name: "Otto"), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      # One card, one like line naming both; the post is quoted once, not per like.
      assert length(rows(html, "post")) == 1
      assert length(lines(html, "like")) == 1
      assert html =~ "Anna Arnold"
      assert html =~ "Ben Otto"
      assert html =~ "like this."
      assert length(String.split(html, "Grouped post body")) - 1 == 1
    end

    test "likes of different posts stay separate cards", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      :ok = Vutuv.Posts.like_post(insert(:user), insert(:post, user: user, body: "First post"))
      :ok = Vutuv.Posts.like_post(insert(:user), insert(:post, user: user, body: "Second post"))

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert length(rows(render(live), "post")) == 2
    end

    test "a local like and a like from another network share one line", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "liked on both sides"})
      :ok = Vutuv.Posts.like_post(insert(:user, first_name: "Anna", last_name: "Arnold"), post)
      remote_reaction!(post, "alice", "like")

      html = render_the_page(conn)

      # One post, one like line: where a like came from is a globe on the name,
      # not a second line saying the same thing.
      assert length(rows(html, "post")) == 1
      assert length(lines(html, "like")) == 1
      assert html =~ "Anna Arnold"
      assert html =~ "@alice@social.example"
      assert html =~ "2 likes"
    end

    test "several followers on one day merge into one line with an overflow link", %{conn: conn} do
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

      # One grouped line: two names spelled out, the rest counted, plural verb.
      assert length(lines(html, "follower")) == 1
      assert html =~ "and 2 more"
      assert html =~ "are now following you."
      # The overflow leads to the member's own followers list.
      assert has_element?(live, ~s(a[href="/#{user.username}/followers"]), "and 2 more")
    end

    test "one endorser's same-day endorsements merge into one line naming every tag", %{
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

      assert length(lines(html, "endorsement")) == 1
      assert html =~ "endorsed you for Elixir and Phoenix."
    end

    test "different endorsers stay separate lines", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      for _ <- 1..2 do
        user_tag = insert(:user_tag, user: user, tag: insert(:tag))
        insert(:user_tag_endorsement, user: insert(:user), user_tag: user_tag)
      end

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert length(lines(render(live), "endorsement")) == 2
    end

    test "cards sit under Berlin-day section headings", %{conn: conn} do
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

    test "a reply line carries the reply's text and opens to the formatted quote", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      replier = insert(:user, first_name: "Joe", last_name: "Armstrong")
      parent = insert(:post, user: user, body: "Which editor do you swear by?")

      reply =
        insert(:post, user: replier, body: "**Neovim**, without a doubt.\n\n- fast\n- everywhere")

      insert(:post_reply, post: reply, parent_post: parent, parent_author: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      # Collapsed: who, what, and the reply's words on one clamped line — plain
      # text, so the markers stay out of it.
      assert has_element?(live, ~s([data-event-kind="reply"]), "Joe Armstrong")
      assert has_element?(live, ~s([data-event-kind="reply"]), "replied.")
      assert has_element?(live, ~s([data-event-kind="reply"] [data-reply-teaser]), "Neovim")
      refute render(live) =~ "**Neovim**"
      refute has_element?(live, ~s([data-reply-preview]))

      # Opened: the reply formatted the way /feed formats a post, its permalink
      # under it as the stretched link, and a Reply link for the answer.
      live |> element(~s([data-event-kind="reply"] [data-line-toggle])) |> render_click()

      html = render(live)
      assert html =~ "<strong>Neovim</strong>"
      assert html =~ "<li>"
      assert has_element?(live, ~s([data-reply-preview] .markdown.markdown--post))

      assert has_element?(
               live,
               ~s([data-reply-preview] a[href="/#{replier.username}/posts/#{reply.id}"])
             )

      assert has_element?(
               live,
               ~s([data-event-kind="reply"] a[data-reply-link][href="/#{replier.username}/posts/#{reply.id}"]),
               "Reply"
             )

      # And it folds again.
      live |> element(~s([data-event-kind="reply"] [data-line-toggle])) |> render_click()
      refute has_element?(live, ~s([data-reply-preview]))
    end

    test "a @mention in an opened reply links to that member", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # The factory's `user-<n>` handle carries a hyphen, which a real handle
      # never may (`Vutuv.Handles.format/0`) and a mention therefore never
      # matches, so this needs a handle-shaped one.
      colleague = insert(:user, username: "quoted_colleague")

      parent = insert(:post, user: user, body: "Who helped?")
      reply = insert(:post, user: insert(:user), body: "Thanks @#{colleague.username}!")
      insert(:post_reply, post: reply, parent_post: parent, parent_author: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      live |> element(~s([data-event-kind="reply"] [data-line-toggle])) |> render_click()

      # The mention keeps its own target, so the quote cannot be one big link:
      # the permalink is a stretched link underneath the body instead.
      assert has_element?(live, ~s([data-reply-preview] a[href="/#{colleague.username}"]))
    end

    test "an answer to someone else in my thread is a thread line under the root's card", %{
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

      # The root's card holds both the direct answer and the deeper one.
      assert length(rows(html, "post")) == 1
      assert length(lines(html, "thread")) == 1
      assert length(lines(html, "reply")) == 1
      assert has_element?(live, ~s([data-post-card]), "The root question")
      assert has_element?(live, ~s([data-event-kind="thread"]), "Joe Armstrong")
      assert has_element?(live, ~s([data-event-kind="thread"]), "replied in the thread.")

      assert has_element?(
               live,
               ~s([data-event-kind="thread"] [data-reply-teaser]),
               "The answer I used to miss"
             )

      live |> element(~s([data-event-kind="thread"] [data-line-toggle])) |> render_click()

      assert has_element?(
               live,
               ~s([data-reply-preview] a[href="/#{other.username}/posts/#{missed.id}"])
             )
    end

    test "every answer in a thread keeps its own line, because each carries its own words", %{
      conn: conn
    } do
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

      assert length(rows(html, "post")) == 1
      assert length(lines(html, "thread")) == 2
      assert length(lines(html, "reply")) == 1
      assert html =~ "Anna Arnold"
      assert html =~ "Ben Otto"
    end

    test "a thread rooted in somebody else's post says whose thread it is", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      host = insert(:user, first_name: "Grace", last_name: "Hopper")
      # No apostrophe in the body: the teaser typesets `'` as `’`, and this
      # test is about whose thread it is, not about quotes.
      root = create_post!(host, %{body: "The root question Grace asked"})
      {:ok, mine} = Vutuv.Posts.create_reply(user, root, %{body: "My answer"})
      # Participation has to predate the answer, and both land in the same
      # second here.
      backdate_reply(mine, NaiveDateTime.add(NaiveDateTime.utc_now(:second), -60))

      {:ok, _} =
        Vutuv.Posts.create_reply(insert(:user, first_name: "Joe"), root, %{
          body: "What Joe answered"
        })

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(
               live,
               ~s([data-kind="post"] [data-card-eyebrow]),
               "Thread by Grace Hopper"
             )

      assert has_element?(live, ~s([data-post-card]), "The root question Grace asked")
    end

    test "only the day's first thread line carries the opt-out hint (issue #1025)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      # Two separate threads the member rooted, each answered by a third party
      # to the first replier - two distinct thread cards on the same day.
      for body <- ["Thread one", "Thread two"] do
        root = insert(:post, user: user, body: body)
        {:ok, first} = Vutuv.Posts.create_reply(insert(:user), root, %{body: "First answer"})
        {:ok, _} = Vutuv.Posts.create_reply(insert(:user), first, %{body: "Third-party answer"})
      end

      {:ok, live, html} = live(conn, ~p"/notifications")

      assert length(lines(html, "thread")) == 2
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

    test "the replies filter keeps thread lines", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      root = insert(:post, user: user, body: "The root question")
      {:ok, first} = Vutuv.Posts.create_reply(insert(:user), root, %{body: "First answer"})
      {:ok, _} = Vutuv.Posts.create_reply(insert(:user), first, %{body: "Deeper answer"})

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=replies")

      assert length(lines(render(live), "thread")) == 1
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
      refute has_element?(live, ~s([data-reply-teaser]))
      refute has_element?(live, ~s([data-line-toggle]))
    end

    test "an opened quote keeps only the first five lines by default", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      body = Enum.map_join(1..7, "\n", &"Line #{&1}")
      reply_with_body!(user, body)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      live |> element(~s([data-event-kind="reply"] [data-line-toggle])) |> render_click()
      html = render(live)

      assert has_element?(live, ~s([data-reply-preview]), "Line 5")
      refute html =~ "Line 6"
      # The shipped default needs no inline override: the .notif-clamp
      # stylesheet fallback already says 5.
      assert has_element?(live, ~s([data-reply-preview] .notif-clamp))
      refute html =~ "--notif-clamp"
    end

    test "an opened quote is wired to reveal the truncation ellipsis", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      reply_with_body!(user, Enum.map_join(1..7, "\n", &"Line #{&1}"))

      {:ok, live, _html} = live(conn, ~p"/notifications")
      live |> element(~s([data-event-kind="reply"] [data-line-toggle])) |> render_click()

      # The server cuts the quote to the reader's line budget, but whether those
      # lines still overflow the box depends on column width and font — only the
      # browser knows. The quote therefore carries the same two markers the
      # feed's post previews use: app.js measures `[data-clamp-body]` and puts
      # `is-clamped` on `[data-post-preview]`, which is what paints the "…"
      # (the shared excerpt-clamp rules in components.css).
      assert has_element?(live, ~s([data-post-preview][phx-hook="PostPreviewClamp"]))
      assert has_element?(live, ~s([data-post-preview] .notif-clamp[data-clamp-body]))
    end

    test "the reader's own line count cuts the opened quote, server-side and in the CSS clamp",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _user} = Vutuv.Accounts.update_user(user, %{"notification_post_lines" => "2"})

      reply_with_body!(user, Enum.map_join(1..7, "\n", &"Line #{&1}"))

      {:ok, live, _html} = live(conn, ~p"/notifications")
      live |> element(~s([data-event-kind="reply"] [data-line-toggle])) |> render_click()
      html = render(live)

      assert has_element?(live, ~s([data-reply-preview]), "Line 2")
      refute html =~ "Line 3"
      assert html =~ "--notif-clamp:2"
    end

    test "the installation default applies to a member who set no line count", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      with_installation_defaults(%{notification_post_lines: 3})

      reply_with_body!(user, Enum.map_join(1..7, "\n", &"Line #{&1}"))

      {:ok, live, _html} = live(conn, ~p"/notifications")
      live |> element(~s([data-event-kind="reply"] [data-line-toggle])) |> render_click()
      html = render(live)

      assert has_element?(live, ~s([data-reply-preview]), "Line 3")
      refute html =~ "Line 4"
      assert html =~ "--notif-clamp:3"
    end

    test "a like on a bodyless (photo-only) post names the post as textless", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post = insert(:post, user: user, body: "")
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert render(live) =~ "likes this."
      assert has_element?(live, ~s([data-post-card-textless]))
    end

    test "non-post notifications carry no post card", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:follow, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert render(live) =~ "started following you"
      refute has_element?(live, ~s([data-post-card]))
    end

    test "a like arriving live brings its post card", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = insert(:post, user: user, body: "Live-quoted post body")

      {:ok, live, _html} = live(conn, ~p"/notifications")

      fan = insert(:user, first_name: "Fanny", last_name: "First")
      Vutuv.Activity.notify_like(user.id, fan, post.id)
      _ = :sys.get_state(live.pid)

      assert has_element?(live, ~s([data-post-card]), "Live-quoted post body")
      assert has_element?(live, ~s([data-event-kind="like"]), "Fanny First")
    end

    test "a live like merges into the derived same-day card for the same post", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post = insert(:post, user: user, body: "Merged live post")
      :ok = Vutuv.Posts.like_post(insert(:user, first_name: "Anna", last_name: "Arnold"), post)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      assert length(rows(render(live), "post")) == 1

      fan = insert(:user, first_name: "Fanny", last_name: "First")
      Vutuv.Activity.notify_like(user.id, fan, post.id)
      _ = :sys.get_state(live.pid)

      html = render(live)
      # Still one card and one like line for the post - now naming both likers.
      assert length(rows(html, "post")) == 1
      assert length(lines(html, "like")) == 1
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

    test "shows a reply as a reply line, but not a self-reply", %{conn: conn} do
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

      assert render(live) =~ "replied."
      assert render(live) =~ "Joe Armstrong"
      # The self-reply derives no line.
      assert length(lines(render(live), "reply")) == 1
    end

    # Every confirmed account carries its own username welcome note, so an
    # utterly empty feed no longer exists; the empty state now belongs to a
    # filter with nothing in it.
    test "shows the empty state for a filter with nothing in it", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=replies")

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

      # The fresh like is highlighted, card and line; the long-seen people card is not.
      assert has_element?(live, ~s([data-notification-row][data-kind="post"][data-unread]))
      assert has_element?(live, ~s([data-event-kind="like"][data-unread]))
      refute has_element?(live, ~s([data-notification-row][data-kind="people"][data-unread]))
      # The header counts what is new since the last visit.
      assert html =~ "1 new notification"
      # And the visit still clears the badge for next time.
      assert Vutuv.Activity.unread_notification_count(user.id) == 0
    end

    test "a reply I already answered is listed but not marked unread", %{conn: conn} do
      # The line stays - the page is the log of what happened - but answering the
      # reply out in the feed already settled it, so it must not read as new
      # here either, or the page and the bell badge would tell two stories.
      {conn, user} = create_and_login_user(conn)
      backdate_welcome_note(user, ~N[2016-11-24 12:00:00])
      set_read_marker(user, ~N[2016-11-25 00:00:00])

      mine = insert(:post, user: user)
      answer = insert(:post, user: insert(:user))
      insert(:post_reply, post: answer, parent_post: mine, parent_author: user)

      {:ok, _reply} = Vutuv.Posts.create_reply(user, answer, %{body: "Thanks!"})

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(live, ~s([data-event-kind="reply"]))
      refute has_element?(live, ~s([data-event-kind="reply"][data-unread]))
      refute has_element?(live, ~s([data-notification-row][data-kind="post"][data-unread]))
    end

    test "within a day, cards with unanswered replies come first and a rule marks the seen ones",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      backdate_welcome_note(user, ~N[2016-11-24 12:00:00])
      # Everything below is newer than the marker; what settles a card is the
      # per-post engagement, not the clock.
      set_read_marker(user, ~N[2016-11-25 00:00:00])

      liked = insert(:post, user: user, body: "The liked one")
      :ok = Vutuv.Posts.like_post(insert(:user), liked)

      answered = insert(:post, user: user, body: "The answered one")
      answer = insert(:post, user: insert(:user), body: "an answer I saw")
      insert(:post_reply, post: answer, parent_post: answered, parent_author: user)
      {:ok, _} = Vutuv.Posts.create_reply(user, answer, %{body: "Thanks!"})

      # Oldest of the three, yet its unanswered reply puts it on top.
      open = insert(:post, user: user, body: "The open one")
      backdate_post(open, NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3600))
      pending = insert(:post, user: insert(:user), body: "a reply waiting for me")
      insert(:post_reply, post: pending, parent_post: open, parent_author: user)
      backdate_reply(pending, NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3600))

      html = render_the_page(conn)

      assert at(html, "The open one") < at(html, "The liked one")
      assert at(html, "The liked one") < at(html, "The answered one")
      # One rule, between the last new card and the first seen one.
      assert length(Regex.scan(~r/data-seen-rule/, html)) == 1
      assert at(html, "The liked one") < at(html, "data-seen-rule")
      assert at(html, "data-seen-rule") < at(html, "The answered one")
    end

    test "no seen-rule when nothing on the page is new", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      :ok = Vutuv.Posts.like_post(insert(:user), insert(:post, user: user, body: "old news"))
      set_read_marker(user, NaiveDateTime.add(NaiveDateTime.utc_now(:second), 60))

      refute render_the_page(conn) =~ "data-seen-rule"
    end

    test "a card shows four lines and folds the rest behind a count", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = insert(:post, user: user, body: "Much discussed")

      for i <- 1..6 do
        reply = insert(:post, user: insert(:user), body: "Answer number #{i}")
        insert(:post_reply, post: reply, parent_post: post, parent_author: user)
      end

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert length(lines(render(live), "reply")) == 4
      assert has_element?(live, ~s([data-card-more]), "Show 2 more")

      live |> element(~s([data-card-more])) |> render_click()

      assert length(lines(render(live), "reply")) == 6
      refute has_element?(live, ~s([data-card-more]))
    end

    test "the card's head counts likes, shares and replies from both sides", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "counted"})
      :ok = Vutuv.Posts.like_post(insert(:user), post)
      remote_reaction!(post, "alice", "like")
      remote_reaction!(post, "bob", "announce")
      remote_note!(post, "carol", "a remote answer")

      insert(:post_reply,
        post: insert(:post, user: insert(:user)),
        parent_post: post,
        parent_author: user
      )

      html = render_the_page(conn)

      assert html =~ "2 likes"
      assert html =~ "1 share"
      assert html =~ "2 replies"
    end

    test "the filter chips count what is new since the last visit", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      backdate_welcome_note(user, ~N[2016-11-24 12:00:00])
      set_read_marker(user, ~N[2016-11-25 00:00:00])

      post = insert(:post, user: user)
      :ok = Vutuv.Posts.like_post(insert(:user), post)
      :ok = Vutuv.Posts.like_post(insert(:user), post)

      insert(:post_reply,
        post: insert(:post, user: insert(:user)),
        parent_post: post,
        parent_author: user
      )

      insert(:follow, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(live, ~s([data-filter-tab="all"] [data-filter-count]), "4")
      assert has_element?(live, ~s([data-filter-tab="replies"] [data-filter-count]), "1")
      assert has_element?(live, ~s([data-filter-tab="reactions"] [data-filter-count]), "2")
      assert has_element?(live, ~s([data-filter-tab="people"] [data-filter-count]), "1")
      refute has_element?(live, ~s([data-filter-tab="other"] [data-filter-count]))
    end

    test "chips carry no counts when nothing is new", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:follow, follower: insert(:user), followee: user)
      set_read_marker(user, NaiveDateTime.add(NaiveDateTime.utc_now(:second), 60))

      {:ok, live, _html} = live(conn, ~p"/notifications")

      refute has_element?(live, ~s([data-filter-count]))
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

    test "the card vocabulary is written German, not fuzzy-filled from something else", %{
      conn: conn
    } do
      # `gettext.extract --merge` fills a brand-new msgid with the translation of
      # whatever looked similar and nothing fails the build, so the German of
      # every new string on this page is asserted by name, the short ones first.
      {conn, user} = create_and_login_user(conn)
      backdate_welcome_note(user, ~N[2016-11-24 12:00:00])
      set_read_marker(user, ~N[2016-11-25 00:00:00])

      host = insert(:user, first_name: "Grace", last_name: "Hopper")
      root = create_post!(host, %{body: "Grace fragt"})
      {:ok, mine} = Vutuv.Posts.create_reply(user, root, %{body: "Meine Antwort"})
      backdate_reply(mine, NaiveDateTime.add(NaiveDateTime.utc_now(:second), -60))
      {:ok, _} = Vutuv.Posts.create_reply(insert(:user), root, %{body: "Joes Antwort"})

      mine = create_post!(user, %{body: "Mein Beitrag"})
      :ok = Vutuv.Posts.like_post(insert(:user), mine)

      insert(:post_reply,
        post: insert(:post, user: insert(:user)),
        parent_post: mine,
        parent_author: user
      )

      answered = create_post!(user, %{body: "Beantwortet"})
      answer = insert(:post, user: insert(:user), body: "gesehen")
      insert(:post_reply, post: answer, parent_post: answered, parent_author: user)
      {:ok, _} = Vutuv.Posts.create_reply(user, answer, %{body: "Danke!"})
      # A like on a card of its own: `mine`'s like line sits behind its fold,
      # and a like on `answered` would make that card new again.
      :ok = Vutuv.Posts.like_post(insert(:user), create_post!(user, %{body: "Nur gelikt"}))

      create_post!(insert(:activated_user), %{body: "Hallo @#{user.username}"})

      for i <- 1..6 do
        reply = insert(:post, user: insert(:user), body: "Antwort #{i}")
        insert(:post_reply, post: reply, parent_post: mine, parent_author: user)
      end

      connect!(user, insert(:user))
      insert(:follow, follower: insert(:user), followee: user)

      {:ok, live, _html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> live(~p"/notifications")

      html = render(live)

      assert html =~ "Ihr Beitrag"
      assert html =~ "Thread von Grace Hopper"
      assert html =~ "hat im Thread geantwortet."
      assert html =~ "hat Sie erwähnt."
      assert html =~ "gefällt das."
      assert html =~ "hat geantwortet."
      assert html =~ "Personen"
      assert html =~ "1 neue Vernetzung"
      assert html =~ "1 neuer Follower"
      assert html =~ "Bereits gesehen"
      # `mine` holds seven answers and a like: four lines shown, four folded.
      assert html =~ "4 weitere anzeigen"
      assert has_element?(live, ~s([data-filter-tab="replies"]), "Antworten")
      assert has_element?(live, ~s([data-filter-tab="reactions"]), "Reaktionen")
      assert has_element?(live, ~s([data-filter-tab="people"]), "Personen")
      assert has_element?(live, ~s([data-filter-tab="other"]), "Mehr")

      live |> element(~s([data-event-kind="thread"] [data-line-toggle])) |> render_click()
      assert has_element?(live, ~s(a[data-reply-link]), "Antworten")
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

  describe "mention lines" do
    test "a post naming the reader is a card headed by that post, under its author", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      author = insert(:activated_user, first_name: "Joe", last_name: "Armstrong")

      post =
        create_post!(author, %{body: "Ask @#{user.username} about the schema, they know it."})

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      assert length(lines(html, "mention")) == 1
      assert has_element?(live, ~s([data-event-kind="mention"]), "Joe Armstrong")
      assert has_element?(live, ~s([data-event-kind="mention"]), "mentioned you.")

      # The head names the post and opens the permalink under the *author* — it
      # is their post, not the reader's, which is what sets this kind apart from
      # a reply or a like — and the eyebrow says so.
      assert has_element?(live, ~s([data-post-card]), "they know it")

      assert has_element?(
               live,
               ~s([data-post-card][href="/#{author.username}/posts/#{post.id}"])
             )

      assert has_element?(live, ~s([data-card-eyebrow]), "Post by Joe Armstrong")

      # The head IS the quote here, so the line has nothing to unfold.
      refute has_element?(live, ~s([data-event-kind="mention"] [data-line-toggle]))
    end

    test "the replies filter keeps mention lines", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      create_post!(insert(:activated_user), %{body: "Hello @#{user.username}."})

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=replies")

      assert length(lines(render(live), "mention")) == 1
    end
  end

  describe "replies from other networks (#1069)" do
    test "the line carries the reply's words and opens to the conversation, anchored at it", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "why are the trains late"})
      note = remote_note!(post, "ba_eh", "the delays come down to two factors")

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(
               live,
               ~s([data-event-kind="fediverse_reply"] [data-reply-teaser]),
               "the delays come down to two factors"
             )

      live
      |> element(~s([data-event-kind="fediverse_reply"] [data-line-toggle]))
      |> render_click()

      # The quote is what the reader reaches for, so it has to be the link — a
      # readable block of somebody's words that does nothing on tap reads as a
      # broken row. It goes where the row's own sentence goes (the reader's post,
      # not the stranger's server) and lands on this reply among the others.
      assert has_element?(
               live,
               ~s([data-remote-reply-preview] a[href="/#{user.username}/posts/#{post.id}#fediverse-reply-#{note.id}"])
             )
    end

    test "the quote's accessible name is translated", %{conn: conn} do
      # The overlay link has no text of its own, so its aria-label is the only
      # name a screen reader gets. vutuv is a German site, so assert the German
      # by name: a new msgid comes out of the merge untranslated (or worse,
      # fuzzy-filled from something unrelated) and nothing else fails the build.
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "warum sind die Züge zu spät"})
      remote_note!(post, "ba_eh", "die Verspätungen resultieren aus zwei Faktoren")

      {:ok, live, _html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> live(~p"/notifications")

      live
      |> element(~s([data-event-kind="fediverse_reply"] [data-line-toggle]))
      |> render_click()

      assert render(live) =~ ~s(aria-label="Unterhaltung ansehen")
    end
  end

  describe "reactions from other networks (#1068)" do
    test "a boost names the account and says what they did", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "went out into the world"})
      remote_reaction!(post, "alice", "announce")

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render(live)

      assert length(rows(html, "post")) == 1
      assert html =~ "@alice@social.example"
      assert html =~ "shared this."
      # It opens the reader's own post, where the line naming them sits — not
      # the remote copy, which they can still reach from the chip there.
      assert has_element?(live, ~s(a[href="/#{user.username}/posts/#{post.id}"]))
    end

    test "same-day boosts of one post merge into a single line", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "much shared"})
      for name <- ~w(alice bob carol), do: remote_reaction!(post, name, "announce")

      html = render_the_page(conn)

      assert length(rows(html, "post")) == 1
      assert event_kinds(html) == ["share"]
      # A like or share line names three before folding — where a people line
      # names two — so three sharers are all spelled out.
      for name <- ~w(alice bob carol), do: assert(html =~ "@#{name}@social.example")
      refute html =~ "and 1 more"
      assert html =~ "shared this."
    end

    test "a fourth sharer folds into the count", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "much shared"})
      for name <- ~w(alice bob carol dave), do: remote_reaction!(post, name, "announce")

      html = render_the_page(conn)

      assert length(lines(html, "share")) == 1
      assert html =~ "and 1 more"
    end

    test "the account opens its card here rather than leading off the site", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      remote_reaction!(
        create_post!(user, %{body: "went out into the world"}),
        "alice",
        "announce"
      )

      {:ok, live, _html} = live(conn, ~p"/notifications")

      # The same hook every other remote handle on the site wears
      # (`assets/js/mention_card.js` binds the account card to it): a plain
      # click answers "who is this and do I want their posts here" without
      # leaving vutuv for a server the reader has no account on. The `href`
      # stays the anchor's whole truth, so a middle-click, a copied link and a
      # page whose JavaScript never arrived still go there.
      assert has_element?(live, ~s(a[data-remote-actor="alice@social.example"]))
      assert has_element?(live, ~s(a[href="https://social.example/users/alice"]))
    end

    test "the reactions filter keeps them", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      remote_reaction!(create_post!(user, %{body: "filtered"}), "alice", "like")

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=reactions")

      assert length(rows(render(live), "post")) == 1
    end
  end

  describe "one card per post, for everything that came back about it" do
    alias Vutuv.Posts.PostImage
    alias Vutuv.Posts.PostScreenshot

    test "a favourite, a boost and a reply to one post share one card", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "two kinds of answer"})
      remote_reaction!(post, "alice", "announce")
      remote_reaction!(post, "bob", "like")
      remote_note!(post, "carol", "the delays come down to two factors")

      html = render_the_page(conn)

      # One post, one card — the three verbs are three lines inside it, not
      # three cards asking the reader which post each one meant. Replies lead,
      # because each carries its own words.
      assert length(rows(html, "post")) == 1
      assert event_kinds(html) == ~w(fediverse_reply like share)

      assert html =~ "likes this."
      assert html =~ "shared this."
      assert html =~ "replied."
      assert html =~ "the delays come down to two factors"
    end

    test "reactions to two posts stay two cards", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      remote_reaction!(create_post!(user, %{body: "the first one"}), "alice", "like")
      remote_reaction!(create_post!(user, %{body: "the second one"}), "bob", "like")

      html = render_the_page(conn)

      assert length(rows(html, "post")) == 2
      assert html =~ "the first one"
      assert html =~ "the second one"
    end

    test "the card names the post and opens it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "warum sind die Züge zu spät"})
      remote_reaction!(post, "alice", "like")

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(live, "[data-post-card]", "warum sind die Züge zu spät")

      assert has_element?(
               live,
               ~s([data-post-card][href="/#{user.username}/posts/#{post.id}"])
             )
    end

    test "two images ride the card and the rest are counted", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "fünf Bilder"})

      [first, second, third] =
        for position <- 0..2,
            do: insert(:post_image, post: post, user: user, position: position)

      :ok = Vutuv.Posts.like_post(insert(:user), post)

      html = render_the_page(conn)

      # Two thumbnails, then a count: the card's right edge has to sit in the
      # same place whether a post carries two pictures or twenty. A local like
      # earns the pictures exactly as a remote one does.
      assert html =~ PostImage.url(first, "thumb")
      assert html =~ PostImage.url(second, "thumb")
      refute html =~ PostImage.url(third, "thumb")
      assert html =~ ~s(data-images-more="1")
    end

    test "a single image rides alone, with no count", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "ein Bild"})
      image = insert(:post_image, post: post, user: user)
      remote_reaction!(post, "alice", "like")

      html = render_the_page(conn)

      assert html =~ PostImage.url(image, "thumb")
      refute html =~ "data-images-more"
    end

    test "an image the scan still holds never reaches the card", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "noch in Prüfung"})
      insert(:post_image, post: post, user: user, moderation: "pending")
      remote_reaction!(post, "alice", "like")

      # The image proxy 404s on an unreleased picture, so a card that linked to
      # one would draw a broken thumbnail on the reader's own notifications.
      refute render_the_page(conn) =~ "/post_images/"
    end

    test "a link post's ready screenshot rides the card where the pictures would", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "Check https://example.com/page"})

      Vutuv.Repo.insert!(%PostScreenshot{
        post_id: post.id,
        url: "https://example.com/page",
        status: "ready",
        screenshot: "0123456789ab.avif",
        moderation: "approved"
      })

      :ok = Vutuv.Posts.like_post(insert(:user), post)

      html = render_the_page(conn)

      assert html =~ "data-post-card-screenshot"
    end

    test "a pending screenshot shows nothing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "Check https://example.com/page"})

      Vutuv.Repo.insert!(%PostScreenshot{
        post_id: post.id,
        url: "https://example.com/page",
        status: "pending"
      })

      :ok = Vutuv.Posts.like_post(insert(:user), post)

      refute render_the_page(conn) =~ "data-post-card-screenshot"
    end

    test "a post with no text says so instead of showing an empty line", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = insert(:post, user: user, body: "")
      insert(:post_image, post: post, user: user)
      remote_reaction!(post, "alice", "like")

      html = render_the_page(conn)

      assert html =~ ~s(data-post-card-textless)
      assert html =~ "Post without text"
    end

    test "the German is written, not fuzzy-filled from something else", %{conn: conn} do
      # A brand-new msgid comes out of `gettext.extract --merge` fuzzy-filled
      # with the translation of whatever looked similar, and nothing fails the
      # build. vutuv is a German site, so the German is asserted by name.
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "die Züge sind zu spät"})
      remote_reaction!(post, "alice", "like")
      remote_reaction!(post, "bob", "announce")
      remote_note!(post, "carol", "das liegt an zwei Faktoren")

      bodyless = insert(:post, user: user, body: "")
      remote_reaction!(bodyless, "dora", "like")

      {:ok, live, _html} =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> live(~p"/notifications")

      html = render(live)

      assert html =~ "gefällt das."
      assert html =~ "hat das geteilt."
      assert html =~ "hat geantwortet."
      assert html =~ "Beitrag ohne Text"
      assert html =~ "1 Like"
      assert html =~ "1 Antwort"
      assert html =~ "1 Mal geteilt"
    end

    test "the card counts what it holds", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "gut gelaufen"})
      for name <- ~w(alice bob carol), do: remote_reaction!(post, name, "like")
      remote_note!(post, "dora", "schöner Beitrag")

      html = render_the_page(conn)

      assert html =~ "3 likes"
      assert html =~ "1 reply"
    end

    test "a private reply carries its warning on the line, before the reader opens it", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)
      post = create_post!(user, %{body: "why are the trains late"})

      post
      |> remote_note!("ba_eh", "just between us")
      |> Ecto.Changeset.change(audience: "direct")
      |> Vutuv.Repo.update!()

      {:ok, live, _html} = live(conn, ~p"/notifications")

      # The member has to know the reply is private *before* they answer it, so
      # the notice cannot wait behind the toggle.
      assert has_element?(live, ~s([data-event-kind="fediverse_reply"] [data-remote-private]))
    end

    test "unread reactions keep their own marker per line", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      # A minute back, not "now": the marker and the reaction would otherwise
      # land in the same second, and `unread?` compares with `:gt`.
      set_read_marker(user, NaiveDateTime.add(NaiveDateTime.utc_now(:second), -60))
      post = create_post!(user, %{body: "frisch"})
      remote_reaction!(post, "alice", "like")

      html = render_the_page(conn)

      assert html =~ ~s(data-event-kind="like" data-unread="true")
    end
  end

  describe "pagination" do
    # The page size is 50 raw events; a day's followers group into ONE line, so
    # the events are counted through the grouped line's overflow label ("and N
    # more") rather than by counting <article>s.
    test "a long feed is split into numbered pages the reader can patch between", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      for _ <- 1..102, do: insert(:follow, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      # 3 pages: 50 + 50 + 2.
      assert has_element?(live, ~s(nav[aria-label="Pagination"] a[href="/notifications?page=2"]))
      assert has_element?(live, ~s(nav[aria-label="Pagination"] a[href="/notifications?page=3"]))
      refute has_element?(live, ~s(nav[aria-label="Pagination"] a[href="/notifications?page=4"]))
      # 50 raw events in one grouped line: 2 named + 48 counted.
      assert render(live) =~ "and 48 more"

      live |> element(~s(a[href="/notifications?page=2"])) |> render_click()

      # A page REPLACES the list instead of appending to it: still 50 events.
      assert render(live) =~ "and 48 more"
      assert_patched(live, "/notifications?page=2")

      live |> element(~s(a[href="/notifications?page=3"])) |> render_click()

      # The last page holds the leftover 2 events, so its grouped line names
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

    test "paging inside a filter keeps the filter", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = insert(:post, user: user)
      for _ <- 1..60, do: :ok = Vutuv.Posts.like_post(insert(:user), post)
      # People events the "reactions" filter must leave out of both list and count.
      for _ <- 1..60, do: insert(:follow, follower: insert(:user), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=reactions")

      assert has_element?(live, ~s(a[href="/notifications?filter=reactions&page=2"]))
      refute has_element?(live, ~s(nav[aria-label="Pagination"] a[href="/notifications?page=2"]))

      live |> element(~s(a[href="/notifications?filter=reactions&page=2"])) |> render_click()

      # 60 likes = 50 + 10, so the second page of THIS filter holds 10 likes
      # (three named, seven folded) and none of the 60 followers.
      html = render(live)
      assert html =~ "and 7 more"
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

  describe "filter chips" do
    test "?filter=reactions keeps likes, drops replies and people events", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      insert(:follow, follower: insert(:user, first_name: "Grace"), followee: user)
      post = insert(:post, user: user, body: "Filterable post")
      :ok = Vutuv.Posts.like_post(insert(:user, first_name: "Fanny"), post)

      insert(:post_reply,
        post: insert(:post, user: insert(:user)),
        parent_post: post,
        parent_author: user
      )

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=reactions")

      html = render(live)
      assert html =~ "likes this."
      refute html =~ "replied."
      refute html =~ "started following you"
    end

    test "?filter=replies keeps replies, drops likes", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      post = insert(:post, user: user, body: "Filterable post")
      :ok = Vutuv.Posts.like_post(insert(:user, first_name: "Fanny"), post)

      insert(:post_reply,
        post: insert(:post, user: insert(:user)),
        parent_post: post,
        parent_author: user
      )

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=replies")

      html = render(live)
      assert html =~ "replied."
      refute html =~ "likes this."
    end

    test "?filter=people keeps follower events, drops post events", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      insert(:follow, follower: insert(:user, first_name: "Grace"), followee: user)
      post = insert(:post, user: user, body: "Filterable post")
      :ok = Vutuv.Posts.like_post(insert(:user, first_name: "Fanny"), post)

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=people")

      html = render(live)
      assert html =~ "started following you"
      refute html =~ "likes this."
    end

    test "the chips patch the filter without a reload", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:follow, follower: insert(:user, first_name: "Grace"), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      assert has_element?(live, ~s([data-filter-tab="all"][aria-current="page"]))

      live
      |> element(~s([data-filter-tab="reactions"]))
      |> render_click()

      assert_patch(live, ~p"/notifications?filter=reactions")
      refute render(live) =~ "started following you"
    end

    # A chip switch reloads the whole list, so on a slow line nothing in the DOM
    # moves between the press and a page of rows arriving — a control that
    # reads as dead. The press paints itself instead, which is CSS on
    # LiveView's own `phx-click-loading` (`assets/css/app.css`) and cannot be
    # asserted here. What this pins is the markup that paint silently needs.
    test "the chips and the list sit inside one scope", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:follow, follower: insert(:user, first_name: "Grace"), followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      # `[data-filter-scope]:has([data-filter-tab].phx-click-loading)
      # [data-filter-list]` — move either marker out of that container and the
      # feedback dies with every other test still green.
      assert has_element?(live, ~s([data-filter-scope] [data-filter-tab="replies"]))
      assert has_element?(live, ~s([data-filter-scope] [data-filter-list]))

      # And the bar names which of the app's two tab looks the paint wears; the
      # default is the /feed brand pill, which would be wrong on this trough.
      assert has_element?(live, ~s([data-filter-bar="track"] [data-filter-tab]))
    end

    test "a live event outside the active filter is not shown", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = insert(:post, user: user, body: "Filtered live post")

      {:ok, live, _html} = live(conn, ~p"/notifications?filter=people")

      Vutuv.Activity.notify_like(user.id, insert(:user, first_name: "Fanny"), post.id)
      _ = :sys.get_state(live.pid)

      refute render(live) =~ "likes this."
    end
  end

  describe "the rail and the summary line" do
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

    test "summarizes the last 30 days in one line under the title", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:follow, follower: insert(:user), followee: user)
      :ok = Vutuv.Posts.like_post(insert(:user), insert(:post, user: user))

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(live, "#activity-summary", "Last 30 days")
      assert has_element?(live, "#activity-summary", "1 follower")
      assert has_element?(live, "#activity-summary", "1 like")
    end

    test "shows no summary line when the window is empty", %{conn: conn} do
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
      assert has_element?(live, ~s([data-post-card]), "Ship the redesign on Friday")

      send(live.pid, :day_changed)
      _ = :sys.get_state(live.pid)
      assert has_element?(live, ~s([data-post-card]), "Ship the redesign on Friday")
    end
  end

  # ── helpers ──

  # Written straight to the table: the inbox gates are the Fediverse tests'
  # business, this is about the line the reader gets.
  defp remote_reaction!(post, name, kind) do
    Vutuv.Repo.insert!(%Vutuv.Fediverse.Reaction{
      post_id: post.id,
      actor_uri: "https://social.example/users/#{name}",
      handle: name,
      kind: kind,
      received_at: DateTime.utc_now(:second)
    })
  end

  defp remote_note!(post, name, text) do
    Vutuv.Repo.insert!(%Vutuv.Fediverse.Note{
      post_id: post.id,
      object_uri:
        "https://social.example/users/#{name}/statuses/#{System.unique_integer([:positive])}",
      actor_uri: "https://social.example/users/#{name}",
      handle: name,
      display_name: String.capitalize(name),
      content_text: text,
      audience: "public",
      received_at: DateTime.utc_now(:second),
      expires_at: DateTime.add(DateTime.utc_now(:second), 30, :day)
    })
  end

  # One reply to a fresh post of `user`'s, with `body` as the reply's text.
  defp reply_with_body!(user, body) do
    parent = insert(:post, user: user, body: "The question")
    reply = insert(:post, user: insert(:user), body: body)
    insert(:post_reply, post: reply, parent_post: parent, parent_author: user)
    reply
  end

  defp render_the_page(conn) do
    {:ok, live, _html} = live(conn, ~p"/notifications")
    render(live)
  end

  # Cards and single rows carry `data-kind`; the lines inside a card carry
  # `data-event-kind`, so counting one never counts the other.
  defp rows(html, kind), do: Regex.scan(~r/data-kind="#{kind}"/, html)
  defp lines(html, kind), do: Regex.scan(~r/data-event-kind="#{kind}"/, html)

  # The lines inside the cards, one per merged event, in document order.
  defp event_kinds(html) do
    ~r/data-event-kind="([a-z_]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, kind] -> kind end)
  end

  # Source-order position of `needle`, so a test can pin that one piece of
  # markup comes before another.
  defp at(html, needle) do
    assert {start, _length} = :binary.match(html, needle)
    start
  end

  defp backdate_follow(%Vutuv.Social.Follow{id: id}, at) do
    import Ecto.Query

    Vutuv.Repo.update_all(
      from(c in Vutuv.Social.Follow, where: c.id == ^id),
      set: [inserted_at: at]
    )
  end

  defp backdate_post(%Vutuv.Posts.Post{id: id}, at) do
    import Ecto.Query

    Vutuv.Repo.update_all(from(p in Vutuv.Posts.Post, where: p.id == ^id), set: [inserted_at: at])
  end

  # A reply event is timestamped by its post_replies row, so an old answer
  # needs that row backdated, not only the reply post.
  defp backdate_reply(%Vutuv.Posts.Post{id: id}, at) do
    import Ecto.Query

    Vutuv.Repo.update_all(
      from(r in Vutuv.Posts.PostReply, where: r.post_id == ^id),
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
