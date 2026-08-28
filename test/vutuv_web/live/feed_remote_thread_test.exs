defmodule VutuvWeb.FeedRemoteThreadTest do
  @moduledoc """
  Replies written on other networks inside the **feed's** threads.

  The permalink has shown them since issue #1069, woven among the vutuv replies
  in time order; the feed's nested thread walked local `reply_ref` links only,
  so a conversation that ran through another network arrived at the reader with
  its middle missing — and a member who answered such a reply looked like they
  were talking to themselves.

  Not async: `Vutuv.RateLimiter` is a shared ETS table the SQL sandbox does not
  roll back, and answering a note claims from it.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts
  alias Vutuv.Social

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  # The viewer, who follows somebody — /feed sends a member who follows nobody
  # to their own profile instead, so the timeline would never render.
  defp reader(conn) do
    {conn, user} = create_and_login_user(conn)
    Social.follow(user, insert(:user, email_confirmed?: true).id)
    {conn, user}
  end

  defp note_under(post, body, attrs \\ []) do
    now = DateTime.utc_now(:second)
    unique = System.unique_integer([:positive])
    handle = attrs[:handle] || "them"

    Repo.insert!(%Note{
      post_id: post.id,
      object_uri: "https://social.example/n/#{unique}",
      actor_uri: "https://social.example/users/#{handle}",
      origin_url: "https://social.example/@#{handle}/#{unique}",
      handle: handle,
      display_name: String.capitalize(handle),
      content_text: body,
      audience: attrs[:audience] || "public",
      inbox_uri: "https://social.example/users/#{handle}/inbox",
      received_at: attrs[:received_at] || now,
      checked_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
  end

  # A post out there, cached here because somebody follows its author.
  defp cached_post(body) do
    now = DateTime.utc_now(:second)
    unique = System.unique_integer([:positive])

    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: "https://social.example/users/them",
        host: "social.example",
        handle: "them",
        name: "Thea Remote",
        inbox_uri: "https://social.example/users/them/inbox"
      })

    Repo.insert!(%RemotePost{
      remote_account_id: account.id,
      object_uri: "https://social.example/p/#{unique}",
      origin_url: "https://social.example/@them/#{unique}",
      content_text: body,
      audience: "public",
      kind: "note",
      published_at: now,
      received_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
    |> Repo.preload(:remote_account)
  end

  defp timeline(view) do
    if has_element?(view, "#feed-posts"), do: render(element(view, "#feed-posts")), else: ""
  end

  describe "a reply from another network is part of the thread the feed shows" do
    test "it renders under the post it answers", %{conn: conn} do
      {conn, user} = reader(conn)
      {:ok, post} = Posts.create_post(user, %{body: "eine Frage in die Runde"})
      note_under(post, "die Antwort von draussen")

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert timeline(view) =~ "eine Frage in die Runde"
      assert timeline(view) =~ "die Antwort von draussen"
      # The card names who said it, so the reader can tell it apart from a
      # vutuv voice without reading the skin.
      assert timeline(view) =~ "@them@social.example"
    end

    test "a member's answer to such a reply hangs under it, not beside it", %{conn: conn} do
      # The gap that read as talking to oneself: both halves were local posts,
      # so the feed drew them as one conversation with nothing in between.
      {conn, user} = reader(conn)
      answerer = insert(:activated_user, fediverse_followers?: true)
      {:ok, _actor} = Fediverse.ensure_actor(answerer)
      Social.follow(user, answerer.id)

      {:ok, post} = Posts.create_post(user, %{body: "eine Frage in die Runde"})
      note = note_under(post, "die Antwort von draussen")

      {:ok, _reply} =
        Posts.create_remote_reply(Repo.reload!(answerer), note, %{body: "und mein Nachsatz"})

      {:ok, view, _html} = live(conn, ~p"/feed")

      html = timeline(view)
      assert html =~ "eine Frage in die Runde"
      assert html =~ "die Antwort von draussen"
      assert html =~ "und mein Nachsatz"

      # Reading order is the nesting: the note sits between the two vutuv posts.
      assert :binary.match(html, "die Antwort von draussen") <
               :binary.match(html, "und mein Nachsatz")
    end

    test "a reply addressed to the author alone reaches nobody else", %{conn: conn} do
      # `Fediverse.list_notes/2`'s viewer scope (issue #1071) has to survive the
      # trip through the feed, where the reader is not always the author.
      {conn, user} = reader(conn)
      author = insert(:user, email_confirmed?: true)
      Social.follow(user, author.id)
      {:ok, post} = Posts.create_post(author, %{body: "ein Beitrag von jemand anderem"})
      note_under(post, "nur fuer die Autorin", audience: "direct")

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert timeline(view) =~ "ein Beitrag von jemand anderem"
      refute timeline(view) =~ "nur fuer die Autorin"
    end

    test "its ⋯ menu works here, instead of taking the page down", %{conn: conn} do
      # The card's menu offers Report to every signed-in reader and Remove to
      # the post's author, and an unhandled `phx-click` kills the LiveView — so
      # a surface that renders the card owes both events. The feed already drew
      # this card for a reshared reply (issue #1275) without them.
      {conn, user} = reader(conn)
      {:ok, post} = Posts.create_post(user, %{body: "eine Frage in die Runde"})
      note = note_under(post, "die Antwort von draussen")

      {:ok, view, _html} = live(conn, ~p"/feed")
      assert timeline(view) =~ "die Antwort von draussen"

      render_click(view, "remove-remote-reply", %{"id" => note.id})

      refute timeline(view) =~ "die Antwort von draussen"
      assert timeline(view) =~ "eine Frage in die Runde"
      assert render(view) =~ "Reply removed."
    end

    test "reporting a reshared reply takes its row off the feed", %{conn: conn} do
      {conn, user} = reader(conn)
      author = insert(:user, email_confirmed?: true)
      Social.follow(user, author.id)
      {:ok, post} = Posts.create_post(author, %{body: "ein Beitrag von jemand anderem"})
      note = note_under(post, "eine weitergereichte Antwort")
      Repo.insert!(%Vutuv.Fediverse.NoteRepost{user_id: author.id, note_id: note.id})

      {:ok, view, _html} = live(conn, ~p"/feed")
      assert timeline(view) =~ "eine weitergereichte Antwort"

      render_click(view, "report-remote-reply", %{"id" => note.id})

      refute timeline(view) =~ "eine weitergereichte Antwort"
    end

    test "answering a post out there shows that post above the answer", %{conn: conn} do
      # The other half of the same gap (issue #1165): the answer is an ordinary
      # vutuv post here, so the feed drew it alone, over a one-line "Replying to
      # @them@social.example" — a reply with nothing to read above it.
      {conn, user} = reader(conn)
      answerer = insert(:activated_user, fediverse_followers?: true)
      {:ok, _actor} = Fediverse.ensure_actor(answerer)
      Social.follow(user, answerer.id)

      remote = cached_post("was da draussen steht")

      {:ok, _post} =
        Posts.create_remote_post_reply(Repo.reload!(answerer), remote, %{
          body: "meine Antwort darauf"
        })

      {:ok, view, _html} = live(conn, ~p"/feed")

      html = timeline(view)
      assert html =~ "meine Antwort darauf"
      assert html =~ "was da draussen steht"

      assert :binary.match(html, "was da draussen steht") <
               :binary.match(html, "meine Antwort darauf")
    end

    test "two answers to the same post out there draw it once, not twice", %{conn: conn} do
      # This 500ed /feed in production on 2026-08-28. The card's action bar is a
      # LiveComponent keyed by the cached post
      # (`RemoteActionsComponent.dom_id(:remote_post, id)`), so drawing the card
      # above both answers emits one id twice, and LiveView raises
      # `found duplicate ID` inside `render_pending_components/6` — during the
      # **static** render, so the page does not degrade, it 500s. Two members
      # answering the same post out there is ordinary behaviour and needs no
      # unusual data at all: the first such pair in the database took the feed
      # down for every reader who had both answers on one page.
      {conn, user} = reader(conn)
      remote = cached_post("was da draussen steht")

      for body <- ["meine Antwort darauf", "und meine auch"] do
        answerer = insert(:activated_user, fediverse_followers?: true)
        {:ok, _actor} = Fediverse.ensure_actor(answerer)
        Social.follow(user, answerer.id)

        {:ok, _post} =
          Posts.create_remote_post_reply(Repo.reload!(answerer), remote, %{body: body})
      end

      {:ok, view, _html} = live(conn, ~p"/feed")

      html = timeline(view)
      assert html =~ "meine Antwort darauf"
      assert html =~ "und meine auch"

      # The cached post is drawn exactly once — for the first answer that
      # claimed it. The second keeps the bare "Replying to …" line, which is
      # what this feature replaced and is still far better than a 500.
      assert html |> String.split("was da draussen steht") |> length() == 2

      # One action bar for it, too — the bar is what carries the id that
      # raised, and `subject_id` rides every one of its controls as
      # `phx-value-id`. Counting the like control is the closest the DOM comes
      # to counting the LiveComponents; the crash above is the real assertion,
      # and it is what goes red when the fix is taken back out.
      assert html
             |> String.split(~s(phx-value-id="#{remote.id}"))
             |> length() > 1
    end

    test "a reader who does not federate may read it but not pass it on", %{conn: conn} do
      # These cards now reach members who have nothing to do with the
      # fediverse, since the thread they sit in is an ordinary vutuv thread. The
      # bar still offers both acts, and the refusal is what teaches: a heart or
      # a reshare travels back out, so it names the switch and links to it
      # (issue #1349) instead of failing silently.
      {conn, user} = reader(conn)
      refute Fediverse.federated?(user), "the reader must not federate, or this proves nothing"

      {:ok, post} = Posts.create_post(user, %{body: "eine Frage in die Runde"})
      note_under(post, "die Antwort von draussen")

      {:ok, view, _html} = live(conn, ~p"/feed")

      html = view |> element("[data-remote-act='repost']") |> render_click()

      assert html =~ "does not take part in the Fediverse"
      assert html =~ ~p"/settings/fediverse"
      assert Repo.aggregate(Vutuv.Fediverse.NoteRepost, :count) == 0
    end

    test "a post that got many keeps the newest few, not all of them", %{conn: conn} do
      # A post that goes round out there can collect dozens of answers, and the
      # feed is not the place to read them: the permalink is.
      {conn, user} = reader(conn)
      {:ok, post} = Posts.create_post(user, %{body: "eine Frage in die Runde"})
      now = DateTime.utc_now(:second)

      for i <- 1..6 do
        note_under(post, "Antwort Nummer #{i}",
          handle: "user#{i}",
          received_at: DateTime.add(now, i)
        )
      end

      {:ok, view, _html} = live(conn, ~p"/feed")

      html = timeline(view)
      assert html =~ "Antwort Nummer 6"
      assert html =~ "Antwort Nummer 4"
      refute html =~ "Antwort Nummer 1"
    end
  end
end
