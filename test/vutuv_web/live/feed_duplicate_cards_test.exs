defmodule VutuvWeb.FeedDuplicateCardsTest do
  @moduledoc """
  The pathological feed: one page carrying **two of everything** that could
  claim the same card.

  This module exists because of a production outage. On 2026-08-28 `/feed`
  started answering 500 for readers whose page held two member posts answering
  the same cached fediverse post: each drew the parent card, the card's action
  bar is a LiveComponent keyed by that post
  (`RemoteActionsComponent.dom_id/1`), and a repeated LiveView id raises inside
  `Phoenix.LiveView.Diff.render_pending_components/6` during the **static**
  render. The page does not degrade, it dies. Nothing in the suite caught it
  because every fixture had exactly one answer per remote post — the bug needed
  a data shape that did not exist until a member produced it.

  So the guard is data, not prose: build the page that a careless dedup would
  choke on, and let LiveView's own duplicate-id check do the asserting. It fires
  for any code path, including ones nobody has written yet, which is the point.
  **When a new kind of card can reach the feed twice, add its pair here.**

  The rule those paths owe is one card per subject per page, keyed by
  `Vutuv.Fediverse.subject_key/1` — the same identity the DOM id is built from,
  so the two cannot drift.

  Not async: answering a note claims from `Vutuv.RateLimiter`, a shared ETS
  table the SQL sandbox does not roll back.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.NoteRepost
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts
  alias Vutuv.Social

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp reader(conn) do
    {conn, user} = create_and_login_user(conn)
    Social.follow(user, insert(:user, email_confirmed?: true).id)
    {conn, user}
  end

  # A member who may answer things out there, followed by the reader so their
  # posts reach the page at all.
  defp answerer(reader) do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)
    Social.follow(reader, user.id)
    Repo.reload!(user)
  end

  defp remote_account do
    unique = System.unique_integer([:positive])

    Repo.insert!(%RemoteAccount{
      actor_uri: "https://social.example/users/them#{unique}",
      host: "social.example",
      handle: "them#{unique}",
      name: "Thea Remote",
      inbox_uri: "https://social.example/users/them#{unique}/inbox"
    })
  end

  defp cached_post(body) do
    now = DateTime.utc_now(:second)
    unique = System.unique_integer([:positive])

    Repo.insert!(%RemotePost{
      remote_account_id: remote_account().id,
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

  defp note_under(post, body) do
    now = DateTime.utc_now(:second)
    unique = System.unique_integer([:positive])

    Repo.insert!(%Note{
      post_id: post.id,
      object_uri: "https://social.example/n/#{unique}",
      actor_uri: "https://social.example/users/them",
      origin_url: "https://social.example/@them/#{unique}",
      handle: "them",
      display_name: "Thea Remote",
      content_text: body,
      audience: "public",
      inbox_uri: "https://social.example/users/them/inbox",
      received_at: now,
      checked_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
  end

  # How many cards a cached post got. `data-remote-post` rides every one of
  # them, so this counts the thing whose repeated LiveComponent id is fatal.
  defp cards_for(html, %RemotePost{id: id}),
    do: (html |> String.split(~s(data-remote-post="#{id}")) |> length()) - 1

  test "two member posts answering one cached post", %{conn: conn} do
    # The exact shape that took /feed down (v7.422.1).
    {conn, user} = reader(conn)
    remote = cached_post("was da draussen steht")

    for body <- ["erste Antwort", "zweite Antwort"] do
      {:ok, _post} = Posts.create_remote_post_reply(answerer(user), remote, %{body: body})
    end

    {:ok, view, _html} = live(conn, ~p"/feed")

    html = render(view)
    assert html =~ "erste Antwort"
    assert html =~ "zweite Antwort"
    # One card, not two — and not zero either: the answers still show what they
    # answer, which is the whole point of the feature.
    assert cards_for(html, remote) == 1
  end

  test "a note that is both reshared on its own and threaded under its post", %{conn: conn} do
    # `standalone_note_ids/1` exists for this: the reshare gives the note a row
    # of its own, and the thread under the post it answers would give it a
    # second card.
    {conn, user} = reader(conn)
    {:ok, post} = Posts.create_post(user, %{body: "eine Frage in die Runde"})
    note = note_under(post, "die weitergereichte Antwort")
    Repo.insert!(%NoteRepost{user_id: user.id, note_id: note.id})

    {:ok, view, _html} = live(conn, ~p"/feed")

    assert render(view) =~ "die weitergereichte Antwort"
  end

  test "two member posts answering one note", %{conn: conn} do
    # The note-side twin of the first case. `attach_thread_notes/3` carries a
    # `seen` set across entries for it; this is the data that proves the set is
    # doing something rather than being decoration.
    {conn, user} = reader(conn)
    {:ok, post} = Posts.create_post(user, %{body: "eine Frage in die Runde"})
    note = note_under(post, "die Antwort von draussen")

    for body <- ["mein Nachsatz", "und meiner auch"] do
      {:ok, _reply} = Posts.create_remote_reply(answerer(user), note, %{body: body})
    end

    {:ok, view, _html} = live(conn, ~p"/feed")

    html = render(view)
    assert html =~ "mein Nachsatz"
    assert html =~ "und meiner auch"
  end

  test "a cached post that is both a standalone row and a post's parent", %{conn: conn} do
    # `standalone_remote_post_ids/1`'s case: the reader follows the account, so
    # the cached post has a row of its own, and a member here answered it, which
    # would draw it a second time above the answer.
    {conn, user} = reader(conn)
    remote = cached_post("was da draussen steht")

    # A member the reader follows reshares it, which gives it a row of its own;
    # another answers it, which would draw it again above the answer. Reshared
    # rather than followed-directly because following an account out there is a
    # signed request to a server that does not exist in a test, while the
    # reshare produces the same standalone row.
    {:ok, :reposted} = Fediverse.repost_remote_post(answerer(user), remote)

    {:ok, _post} =
      Posts.create_remote_post_reply(answerer(user), remote, %{body: "meine Antwort darauf"})

    {:ok, view, _html} = live(conn, ~p"/feed")

    html = render(view)
    assert html =~ "meine Antwort darauf"
    assert cards_for(html, remote) == 1
  end

  test "all four shapes on one page at once", %{conn: conn} do
    # Each case above is one careless dedup; a real feed mixes them, and the
    # sets they are checked against are shared. This is the page that finds an
    # interaction between two of them.
    {conn, user} = reader(conn)

    remote = cached_post("was da draussen steht")

    for body <- ["erste Antwort", "zweite Antwort"] do
      {:ok, _post} = Posts.create_remote_post_reply(answerer(user), remote, %{body: body})
    end

    {:ok, post} = Posts.create_post(user, %{body: "eine Frage in die Runde"})
    note = note_under(post, "die Antwort von draussen")
    Repo.insert!(%NoteRepost{user_id: user.id, note_id: note.id})

    for body <- ["mein Nachsatz", "und meiner auch"] do
      {:ok, _reply} = Posts.create_remote_reply(answerer(user), note, %{body: body})
    end

    {:ok, view, _html} = live(conn, ~p"/feed")

    html = render(view)
    assert html =~ "erste Antwort"
    assert html =~ "zweite Antwort"
    assert html =~ "die Antwort von draussen"
    assert html =~ "mein Nachsatz"
  end
end
