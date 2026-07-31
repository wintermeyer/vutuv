defmodule VutuvWeb.PostThreadRemoteRepliesTest do
  @moduledoc """
  Replies written on other networks, as they appear in the permalink's
  conversation (issues #1069 and #1071): who sees them, how they are told apart
  from a vutuv reply, and the takedown controls.

  async: false — the report rate limit lives in the shared `Vutuv.RateLimiter`
  ETS table, which the SQL sandbox does not roll back.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Fediverse.Note
  alias Vutuv.Posts

  @actor "https://social.example/users/alice"

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()
    {conn, user} = create_and_login_user(conn)

    user =
      user
      |> Ecto.Changeset.change(%{fediverse_followers?: true, fediverse_replies?: true})
      |> Repo.update!()

    post = create_post!(user, %{body: "Reachable from anywhere."})

    # The embedded thread resolves the viewer from the cookie's session_token
    # (issue #1036), never a bare user_id, so its tests hand it a real session.
    {:ok, user: user, post: post, owner: Plug.Conn.get_session(conn)}
  end

  defp note!(post, attrs \\ []) do
    now = Keyword.get(attrs, :received_at, DateTime.utc_now(:second))

    Repo.insert!(%Note{
      post_id: post.id,
      object_uri: Keyword.get(attrs, :object_uri, "#{@actor}/statuses/1"),
      actor_uri: Keyword.get(attrs, :actor_uri, @actor),
      origin_url: "https://social.example/@alice/1",
      handle: Keyword.get(attrs, :handle, "alice"),
      display_name: Keyword.get(attrs, :display_name, "Alice Anders"),
      content_text: Keyword.get(attrs, :content_text, "Sturdier than they look."),
      summary: Keyword.get(attrs, :summary),
      audience: Keyword.get(attrs, :audience, "public"),
      received_at: now,
      checked_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
  end

  defp thread_view(post, cookie \\ %{}) do
    session = Map.merge(cookie, %{"post_id" => post.id, "locale" => "en"})

    live_isolated(build_conn(), VutuvWeb.PostLive.Thread, session: session)
  end

  # A second logged-in member, with their cookie session. `init_test_session/2`
  # mirrors what ConnCase does to the conn it hands each test — the login flow
  # configures the session, which needs one fetched.
  defp other_member do
    {conn, user} =
      build_conn() |> Plug.Test.init_test_session(%{}) |> create_and_login_user()

    {user, Plug.Conn.get_session(conn)}
  end

  describe "a public reply" do
    test "renders under the post for a logged-out visitor", %{post: post} do
      note = note!(post)

      {:ok, _view, html} = thread_view(post)

      assert html =~ "Sturdier than they look."
      assert html =~ "Alice Anders"
      assert html =~ "@alice@social.example"
      assert html =~ ~s(data-fediverse-reply="#{note.id}")
    end

    test "carries its anchor, so a link can land on it among the others", %{post: post} do
      note = note!(post)

      {:ok, _view, html} = thread_view(post)

      # A remote reply has no permalink of its own, so the notifications quote
      # sends the reader here with this fragment. The two ends share
      # `Fediverse.reply_anchor/1`, but only a rendered id makes the fragment
      # resolve — without it the link silently opens the page at the top.
      assert html =~ ~s(id="#{Vutuv.Fediverse.reply_anchor(note.id)}")
    end

    test "is marked as coming from another network, never disguised as a vutuv reply", %{
      post: post
    } do
      note!(post)

      {:ok, _view, html} = thread_view(post)

      assert html =~ "From another network"
      assert html =~ "social.example"
      assert html =~ "View the original"
      # The link goes to the origin, so the original stays the authoritative copy.
      assert html =~ "https://social.example/@alice/1"
      # Its own visual language: the slate initials tile, not a member avatar.
      assert html =~ "data-remote-avatar"
      # But the text itself reads like a normal reply body — the markers above
      # carry the origin, not a dashed quote rail down the text (2026-07-30).
      [remote_card] = Regex.run(~r{<article data-fediverse-reply.*?</article>}s, html)
      refute remote_card =~ "border-dashed"
    end

    test "shows no action bar, because none of those actions exist for it", %{post: post} do
      note!(post)

      {:ok, _view, html} = thread_view(post)

      refute html =~ "data-fediverse-reply=\"\" "
      # A vutuv card would carry the like/repost/bookmark bar; this one must not
      # offer controls that cannot work on somebody else's server.
      [remote_card] = Regex.run(~r{<article data-fediverse-reply.*?</article>}s, html)
      refute remote_card =~ "phx-click=\"toggle-like\""
      refute remote_card =~ "post-actions"
    end

    test "a content warning stays closed until the reader opens it", %{post: post} do
      note!(post, summary: "Spoiler: Staffelfinale", content_text: "Er stirbt.")

      {:ok, _view, html} = thread_view(post)

      assert html =~ "data-remote-warning"
      assert html =~ "Spoiler: Staffelfinale"
      # `<details>` keeps the body out of view until clicked; it is in the DOM
      # but behind the lid its author asked for.
      assert html =~ "<details"
    end

    test "its links are clickable, not raw strings", %{post: post} do
      # A post on those networks is largely links. Stored as plain text, they
      # used to sit on the card unclickable and wrapping mid-URL.
      note!(post, content_text: "Worth reading: https://taz.de/Klimaschutzvorgaben/!6199402/")

      {:ok, _view, html} = thread_view(post)

      assert html =~ ~s(href="https://taz.de/Klimaschutzvorgaben/!6199402/")
      # New tab, and no ranking credit passed to a stranger's link.
      assert html =~ "noopener"
    end

    test "a bare @mention stays plain text, it never links a local member", %{post: post} do
      # Over there `@name` names an account in the fediverse, not the vutuv
      # member who happens to share the handle — linking it would point the
      # reader at the wrong person.
      # A real, mentionable handle: the factory's `user-1` carries a hyphen,
      # which the mention grammar stops at, so it would prove nothing.
      member = insert(:activated_user, username: unique_username())
      note!(post, content_text: "Ask @#{member.username} about it.")

      {:ok, _view, html} = thread_view(post)

      assert html =~ "Ask @#{member.username} about it."
      refute html =~ ~s(href="/#{member.username}")
    end

    test "a lone post with only a remote reply still renders the conversation", %{post: post} do
      # The single-card shortcut must not swallow the one answer the post got.
      note!(post)

      {:ok, _view, html} = thread_view(post)

      assert html =~ "post-thread"
      assert html =~ "Sturdier than they look."
    end

    test "sits in time order among the vutuv replies", %{post: post, owner: owner} do
      # Explicit stamps: three rows created in the same second would tie, and a
      # tie proves nothing about ordering.
      base = ~N[2026-07-25 10:00:00]

      {:ok, early} = Posts.create_reply(insert(:activated_user), post, %{body: "First in."})
      {:ok, late} = Posts.create_reply(insert(:activated_user), post, %{body: "Last in."})

      early |> Ecto.Changeset.change(inserted_at: base) |> Repo.update!()
      late |> Ecto.Changeset.change(inserted_at: NaiveDateTime.add(base, 120)) |> Repo.update!()

      note!(post,
        received_at: base |> NaiveDateTime.add(60) |> DateTime.from_naive!("Etc/UTC")
      )

      {:ok, _view, html} = thread_view(post, owner)

      early = :binary.match(html, "First in.") |> elem(0)
      remote = :binary.match(html, "Sturdier than they look.") |> elem(0)
      late = :binary.match(html, "Last in.") |> elem(0)

      assert early < remote and remote < late
    end
  end

  describe "a reply sent to the member alone (#1071)" do
    test "is invisible to a logged-out visitor", %{post: post} do
      note!(post, audience: "direct", content_text: "This one is between us.")

      {:ok, _view, html} = thread_view(post)

      refute html =~ "This one is between us."
    end

    test "is invisible to another member", %{post: post} do
      note!(post, audience: "direct", content_text: "This one is between us.")

      {_other, cookie} = other_member()
      {:ok, _view, html} = thread_view(post, cookie)

      refute html =~ "This one is between us."
    end

    test "the addressed member sees it, and is told nobody else does", %{post: post, owner: owner} do
      note!(post, audience: "direct", content_text: "This one is between us.")

      {:ok, _view, html} = thread_view(post, owner)

      assert html =~ "This one is between us."
      assert html =~ "data-remote-private"
      assert html =~ "Sent to you only, visible to nobody else"
    end

    test "an audience we could not read is treated the same way", %{post: post, owner: owner} do
      note!(post, audience: "unknown", content_text: "Ambiguous delivery.")

      {:ok, _view, html} = thread_view(post)
      refute html =~ "Ambiguous delivery."

      {:ok, _view, html} = thread_view(post, owner)
      assert html =~ "Ambiguous delivery."
    end
  end

  describe "takedown" do
    test "the member removes a reply from their own post", %{post: post, owner: owner} do
      note = note!(post)

      {:ok, view, _html} = thread_view(post, owner)

      assert render(view) =~ "Sturdier than they look."

      html =
        view
        |> element(~s([phx-click="remove-remote-reply"][phx-value-id="#{note.id}"]))
        |> render_click()

      refute html =~ "Sturdier than they look."
      refute Repo.get(Note, note.id)
    end

    test "another member has no Remove, but can report", %{post: post} do
      note = note!(post)
      {_other, cookie} = other_member()

      {:ok, view, html} = thread_view(post, cookie)

      refute html =~ ~s(phx-click="remove-remote-reply")

      html =
        view
        |> element(~s([phx-click="report-remote-reply"][phx-value-id="#{note.id}"]))
        |> render_click()

      # Deleted right away — no case workflow, nothing to work through.
      refute html =~ "Sturdier than they look."
      refute Repo.get(Note, note.id)
      assert Repo.aggregate(Vutuv.Moderation.Case, :count) == 0
    end

    test "a logged-out visitor gets no controls at all", %{post: post} do
      note!(post)

      {:ok, _view, html} = thread_view(post)

      refute html =~ ~s(phx-click="report-remote-reply")
      refute html =~ ~s(phx-click="remove-remote-reply")
    end

    test "the takedown is logged for the operator, without content or URIs", %{
      post: post,
      owner: owner
    } do
      note = note!(post)

      {:ok, view, _html} = thread_view(post, owner)

      view
      |> element(~s([phx-click="remove-remote-reply"][phx-value-id="#{note.id}"]))
      |> render_click()

      assert [event] = Repo.all(Vutuv.Fediverse.NoteEvent)
      assert event.action == "removed_by_member"
      assert event.host == "social.example"

      encoded = inspect(Map.from_struct(event))
      refute encoded =~ "Sturdier than they look."
      refute encoded =~ @actor
    end
  end
end
