defmodule VutuvWeb.NotificationLiveTest do
  @moduledoc """
  /notifications as one timeline with the member's looks drawn as lines
  (`VutuvWeb.NotificationLive.Index`, `VutuvWeb.NotificationLive.Timeline`).

  Sync (the ConnCase default): reporting a reply from another network claims
  from `Vutuv.RateLimiter`, a shared ETS table the SQL sandbox does not roll
  back.
  """
  use VutuvWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Vutuv.Activity
  alias Vutuv.Activity.NotificationVisit
  alias Vutuv.Fediverse.Note
  alias Vutuv.Posts
  alias Vutuv.Posts.PostLike
  alias Vutuv.Posts.PostReply
  alias Vutuv.Social.Follow

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp ago(minutes), do: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -minutes, :minute)

  defp new_follower!(user, attrs \\ [], at \\ nil) do
    follow = insert(:follow, follower: insert(:user, attrs), followee: user)

    if at,
      do: Repo.update_all(from(f in Follow, where: f.id == ^follow.id), set: [inserted_at: at])

    follow
  end

  defp visit!(user, at) do
    Repo.insert!(%NotificationVisit{
      user_id: user.id,
      source: "page",
      at: DateTime.from_naive!(at, "Etc/UTC")
    })
  end

  defp like!(post, liker, at \\ nil) do
    :ok = Posts.like_post(liker, post)

    if at,
      do:
        Repo.update_all(
          from(l in PostLike, where: l.user_id == ^liker.id and l.post_id == ^post.id),
          set: [inserted_at: at]
        )
  end

  # A reply by somebody else to one of the member's posts.
  defp reply!(user, body, parent_body \\ "Die Frage") do
    parent = insert(:post, user: user, body: parent_body)
    reply = insert(:post, user: insert(:activated_user), body: body)
    insert(:post_reply, post: reply, parent_post: parent, parent_author: user)
    {parent, reply}
  end

  defp remote_note!(post, name, text) do
    Repo.insert!(%Note{
      post_id: post.id,
      object_uri:
        "https://social.example/users/#{name}/statuses/#{System.unique_integer([:positive])}",
      actor_uri: "https://social.example/users/#{name}",
      inbox_uri: "https://social.example/users/#{name}/inbox",
      handle: name,
      display_name: String.capitalize(name),
      content_text: text,
      audience: "public",
      received_at: DateTime.utc_now(:second),
      checked_at: DateTime.utc_now(:second),
      expires_at: DateTime.add(DateTime.utc_now(:second), 30, :day)
    })
  end

  # Where `needle` first appears in `html`, for order assertions.
  defp position(html, needle) do
    case :binary.match(html, needle) do
      {at, _length} -> at
      :nomatch -> flunk("#{inspect(needle)} is not on the page")
    end
  end

  describe "the page" do
    test "the static render carries the list (issue #919)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      new_follower!(user, first_name: "Grace", last_name: "Hopper")

      body = conn |> get(~p"/notifications") |> html_response(200)

      assert body =~ "Grace Hopper"
      assert body =~ "follows you"
      assert body =~ ~s(data-row="people")
    end

    test "redirects a logged-out visitor to the login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/notifications")
    end

    test "the connected page records the visit and clears the badge", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      new_follower!(user)

      {:ok, _live, _html} = live(conn, ~p"/notifications")

      assert Repo.aggregate(from(v in NotificationVisit, where: v.user_id == ^user.id), :count) ==
               1

      assert Activity.unread_notification_count(Repo.reload!(user)) == 0
    end

    test "greets a confirmed member with their username, three links, no URL at a sentence end",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, live, html} = live(conn, ~p"/notifications")

      assert has_element?(live, ~s([data-kind="username"] a[href="/#{user.username}"]))
      assert html =~ "Welcome to vutuv! You can change your automatically assigned username"
      refute html =~ "/settings/import/linkedin</a>."
      refute html =~ "/settings/username</a>."
      for marker <- ~w({handle} {url} {import_url}), do: refute(html =~ marker)
    end
  end

  describe "visits as lines" do
    test "a look is a line between what came before and after it, and the after is new",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      new_follower!(user, [first_name: "Before", last_name: "Line"], ago(180))
      visit!(user, ago(120))
      new_follower!(user, [first_name: "After", last_name: "Line"], ago(60))

      {:ok, live, html} = live(conn, ~p"/notifications")

      assert html =~ "You were here ·"
      assert position(html, "After Line") < position(html, "You were here ·")
      assert position(html, "You were here ·") < position(html, "Before Line")

      assert has_element?(live, "[data-fresh-line]", "new since your visit at")
      assert has_element?(live, ~s([data-row="people"][data-fresh="true"]), "After Line")
      refute has_element?(live, ~s([data-row="people"][data-fresh="true"]), "Before Line")
    end

    test "a reload within the same sitting keeps what the first look marked new", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      visit!(user, ago(120))
      new_follower!(user, [first_name: "Still", last_name: "New"], ago(60))

      {:ok, _first, _html} = live(conn, ~p"/notifications")
      {:ok, second, _html} = live(conn, ~p"/notifications")

      assert has_element?(second, ~s([data-row="people"][data-fresh="true"]), "Still New")
    end

    test "a look lists in the rail and opens the list as it stood then", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      new_follower!(user, [first_name: "Seen", last_name: "Then"], ago(180))
      visit = visit!(user, ago(120))
      new_follower!(user, [first_name: "Came", last_name: "Later"], ago(60))

      at = visit.at |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()

      # The rail lists the looks of the day it shows. Open the look's own day,
      # which two hours ago is yesterday shortly after midnight.
      day = visit.at |> Vutuv.ViewerClock.date() |> Date.to_iso8601()
      {:ok, live, _html} = live(conn, ~p"/notifications?day=#{day}")

      assert has_element?(live, ~s(#visits-desktop a[data-visit="#{at}"]))

      html = live |> element(~s(#visits-desktop a[data-visit="#{at}"])) |> render_click()

      assert html =~ "As of"
      assert html =~ "Seen Then"
      refute html =~ "Came Later"
      assert has_element?(live, "#travel-banner a", "Back to now")
    end
  end

  describe "rows" do
    test "a reply is the feed's card, headed by what it answers, with my own words under it",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {parent, reply} =
        reply!(user, "Das Logo hat schon jemand eingebunden.", "Wo kommt der Name her?")

      answer =
        insert(:post,
          user: user,
          body: "> Das Logo hat schon jemand eingebunden.\n\nKrass, wie schnell das geht."
        )

      insert(:post_reply, post: answer, parent_post: reply, parent_author: reply.user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      row = ~s([data-row="words"][data-kind="reply"])
      assert has_element?(live, row, "Reply to your post")

      assert has_element?(
               live,
               "#{row} a[href='#{Posts.path(parent)}']",
               "Wo kommt der Name her?"
             )

      assert has_element?(live, row, "Das Logo hat schon jemand eingebunden.")
      # The answer quotes the reply first; what shows is what the member wrote.
      assert has_element?(live, "#{row} [data-answer]", "Krass, wie schnell das geht.")
      refute has_element?(live, "#{row} [data-answer]", "Das Logo hat")
    end

    test "the card's Reply opens the composer under it and an answer folds it away",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {_parent, reply} = reply!(user, "Eine Frage an dich")

      [row_id] =
        Regex.run(~r/id="row-([^"]+)" data-row="words"/, render_page(conn),
          capture: :all_but_first
        )

      {:ok, live, _html} = live(conn, ~p"/notifications")
      render_hook(live, "compose", %{"id" => row_id})
      assert has_element?(live, "#answer-#{row_id}-form")

      live
      |> form("#answer-#{row_id}-form", %{"post" => %{"body" => "Gern geantwortet"}})
      |> render_submit()

      _ = :sys.get_state(live.pid)
      refute has_element?(live, "#answer-#{row_id}-form")
      assert Repo.exists?(from(r in PostReply, where: r.parent_post_id == ^reply.id))
      assert has_element?(live, "[data-answer]", "Gern geantwortet")
    end

    test "likes of one post between two looks are one line", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = insert(:post, user: user, body: "Ein Beitrag")
      like!(post, insert(:user, first_name: "Anna", last_name: "A"))
      like!(post, insert(:user, first_name: "Ben", last_name: "B"))

      {:ok, live, _html} = live(conn, ~p"/notifications")

      # The feed card's bottom line: the heart with its count, the faces, and
      # every name behind them.
      assert has_element?(
               live,
               ~s([data-row="reactions"] [data-reaction="likes"][title="2 likes"]),
               "2"
             )

      refute has_element?(live, ~s([data-row="reactions"] [data-reaction="shares"]))
      assert has_element?(live, ~s([data-row="reactions"] [data-reactor]), "Anna A")
      assert has_element?(live, ~s([data-row="reactions"] [data-reactor]), "Ben B")
      assert length(Regex.scan(~r/data-row="reactions"/, render(live))) == 1
    end

    test "a re-share from another network shows the arrows, not a heart", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = insert(:post, user: user, body: "Weitergereicht")

      Repo.insert!(%Vutuv.Fediverse.Reaction{
        post_id: post.id,
        actor_uri: "https://social.example/users/dendroniker",
        handle: "dendroniker",
        kind: "announce",
        received_at: DateTime.utc_now(:second)
      })

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(
               live,
               ~s([data-row="reactions"] [data-reaction="shares"][title="1 repost"]),
               "1"
             )

      refute has_element?(live, ~s([data-row="reactions"] [data-reaction="likes"]))
      assert has_element?(live, ~s([data-row="reactions"] [data-reactor]), "dendroniker")
    end

    test "a follower who became a connection is one person, and a new one can be followed back",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      mutual = insert(:user, first_name: "Mutual", last_name: "Friend")
      insert(:follow, follower: mutual, followee: user)
      insert(:follow, follower: user, followee: mutual)
      newcomer = insert(:user, first_name: "New", last_name: "Comer")
      insert(:follow, follower: newcomer, followee: user)

      {:ok, live, _html} = live(conn, ~p"/notifications")

      html = render(live)
      assert length(Regex.scan(~r/Mutual Friend/, html)) == 1
      assert has_element?(live, ~s([data-row="people"]), "connected")

      live |> element(~s(button[phx-value-followee="#{newcomer.id}"])) |> render_click()

      assert Repo.exists?(
               from(f in Follow,
                 where: f.follower_id == ^user.id and f.followee_id == ^newcomer.id
               )
             )

      refute has_element?(live, ~s(button[phx-value-followee="#{newcomer.id}"]))
    end

    test "the replies-only switch keeps the cards, and stays on for the next visit",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      reply!(user, "Worte an mich")
      new_follower!(user, first_name: "Some", last_name: "Follower")
      like!(insert(:post, user: user), insert(:user))

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = live |> element("#replies-only") |> render_click()

      assert html =~ "Worte an mich"
      refute html =~ ~s(data-row="people")
      refute html =~ ~s(data-row="reactions")
      assert Repo.reload!(user).notifications_replies_only?

      # A setting of the member's, not of this tab: the next visit, and its
      # static render, open with it on.
      body = conn |> recycle() |> get(~p"/notifications") |> html_response(200)
      assert body =~ ~s(aria-checked="true")
      refute body =~ ~s(data-row="people")

      {:ok, again, _html} = live(conn, ~p"/notifications")
      again |> element("#replies-only") |> render_click()

      refute Repo.reload!(user).notifications_replies_only?
      assert has_element?(again, ~s([data-row="people"]))
    end

    test "a reply from another network is its own card and can be reported", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      post = insert(:post, user: user, body: "Warum sind die Züge spät?")
      note = remote_note!(post, "ba_eh", "Die Verspätungen haben zwei Gründe")

      {:ok, live, _html} = live(conn, ~p"/notifications")

      assert has_element?(
               live,
               ~s([data-kind="fediverse_reply"]),
               "Die Verspätungen haben zwei Gründe"
             )

      live
      |> element(~s([phx-click="report-remote-reply"][phx-value-id="#{note.id}"]))
      |> render_click()

      refute Repo.get(Note, note.id)
      refute render(live) =~ "Die Verspätungen haben zwei Gründe"
    end
  end

  describe "time travel" do
    test "a day from the calendar shows that day and the one before it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      day = Date.add(Vutuv.BerlinTime.today(), -5)
      {midday, _} = Vutuv.ViewerClock.day_window(day)

      new_follower!(
        user,
        [first_name: "Five", last_name: "Days"],
        NaiveDateTime.add(midday, 12, :hour)
      )

      new_follower!(user, first_name: "Right", last_name: "Now")

      {:ok, live, _html} = live(conn, ~p"/notifications")
      render_click(live, "cal-toggle", %{})
      html = render_click(live, "cal-day", %{"date" => Date.to_iso8601(day)})

      assert_patch(live, ~p"/notifications?day=#{Date.to_iso8601(day)}")
      assert html =~ "Five Days"
      refute html =~ "Right Now"
    end

    test "the calendar shades the month by what arrived", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      new_follower!(user)

      {:ok, live, _html} = live(conn, ~p"/notifications")
      html = render_click(live, "cal-toggle", %{})

      # The follow and the welcome note every new member gets.
      assert html =~ "2 notifications on"
    end
  end

  describe "live" do
    test "an arrival shows without a reload and keeps the badge at zero", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/notifications")

      new_follower!(user, first_name: "Live", last_name: "Arrival")
      send(live.pid, {:new_notification, %{kind: "follower"}})
      send(live.pid, :reload)

      assert render(live) =~ "Live Arrival"
      assert Activity.unread_notification_count(Repo.reload!(user)) == 0
    end

    test "a day change re-renders without dropping rows", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      new_follower!(user, first_name: "Stays", last_name: "Put")
      {:ok, live, _html} = live(conn, ~p"/notifications")

      send(live.pid, :day_changed)
      assert render(live) =~ "Stays Put"
    end
  end

  describe "German" do
    test "the new vocabulary is written German, not fuzzy-filled", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      new_follower!(user, [first_name: "Vor", last_name: "Her"], ago(180))
      visit!(user, ago(120))
      reply!(user, "Eine Antwort")
      post = insert(:post, user: user, body: "Gemocht")
      like!(post, insert(:user))
      like!(post, insert(:user))

      body =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/notifications")
        |> html_response(200)

      assert body =~ "Mitteilungen"
      assert body =~ "Nur Antworten und Erwähnungen"
      assert body =~ "Hier waren Sie ·"
      assert body =~ "neu seit Ihrem Besuch um"
      assert body =~ "Antwort auf Ihren Beitrag"
      assert body =~ "2 Likes"
      assert body =~ "folgt Ihnen"
      assert body =~ "Ihre Besuche am"
      assert body =~ "Frühere Tage"
      assert body =~ "Ein Besuch zeigt die Liste so, wie sie in dem Moment aussah."

      assert body =~
               "Willkommen bei vutuv! Sie können Ihren automatisch zugewiesenen Benutzernamen"
    end

    test "time travel speaks German too", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      visit = visit!(user, ago(120))
      at = visit.at |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()

      body =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/notifications?at=#{at}")
        |> html_response(200)

      assert body =~ "Stand "
      assert body =~ "So sah die Liste aus, als Sie hier waren."
      assert body =~ "Zurück zu jetzt"
    end
  end

  defp render_page(conn), do: conn |> get(~p"/notifications") |> html_response(200)
end
