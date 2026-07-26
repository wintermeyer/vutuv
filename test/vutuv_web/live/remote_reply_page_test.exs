defmodule VutuvWeb.RemoteReplyPageTest do
  @moduledoc """
  Answering a reply that came from another network (issue #1070), from the
  member's side: who is offered the action, what a member who does not federate is
  told instead of being stonewalled, and that the answer lands back in the
  conversation nested under the reply it answers.

  async: false — the outbound reply budget lives in the shared
  `Vutuv.RateLimiter` ETS table, which the SQL sandbox does not roll back.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Fediverse.Note
  alias Vutuv.Posts

  @actor "https://social.example/users/alice"
  @inbox "https://social.example/users/alice/inbox"

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()
    {conn, user} = create_and_login_user(conn)

    user
    |> Ecto.Changeset.change(%{fediverse_followers?: true, fediverse_replies?: true})
    |> Repo.update!()

    # Re-read: the struct `register_user` returned predates the PIN login that
    # confirmed the address, and `Fediverse.federated?/1` reads
    # `email_confirmed?`.
    user = Repo.get!(Vutuv.Accounts.User, user.id)

    post = create_post!(user, %{body: "Reachable from anywhere."})

    {:ok, conn: conn, user: user, post: post, note: note!(post)}
  end

  defp note!(post, attrs \\ []) do
    now = DateTime.utc_now(:second)

    Repo.insert!(%Note{
      post_id: post.id,
      object_uri: "#{@actor}/statuses/#{System.unique_integer([:positive])}",
      actor_uri: @actor,
      inbox_uri: @inbox,
      origin_url: "https://social.example/@alice/1",
      handle: "alice",
      display_name: "Alice Anders",
      content_text: "Sturdier than they look.",
      audience: Keyword.get(attrs, :audience, "public"),
      received_at: now,
      checked_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
  end

  describe "the page a federating member gets" do
    test "shows the reply, the composer, and where the words are going", %{
      conn: conn,
      note: note
    } do
      {:ok, _view, html} = live(conn, ~p"/system/fediverse/reply/#{note.id}")

      assert html =~ "Sturdier than they look."
      assert html =~ "data-remote-reply-notice"
      # Said before they type: nobody should publish to another network by
      # accident.
      assert html =~ "@alice@social.example"
      assert html =~ "your Fediverse followers"
      refute html =~ "Turn on Fediverse participation"
    end

    test "the composer carries no corner ✕ (its close event lives on the feed alone)", %{
      conn: conn,
      note: note
    } do
      # The feed's corner ✕ bubbles `close-composer` up to whatever
      # LiveView hosts the composer, and this page has no handler for it — a
      # click here crashed the page instead of doing nothing.
      {:ok, view, _html} = live(conn, ~p"/system/fediverse/reply/#{note.id}")

      refute has_element?(view, ~s(button[phx-click="close-composer"]))
    end

    test "sends the answer and lands back in the conversation", %{conn: conn, note: note} do
      {:ok, view, _html} = live(conn, ~p"/system/fediverse/reply/#{note.id}")

      view
      |> form("#composer-form", %{"post" => %{"body" => "Danke, Alice!"}})
      |> render_submit()

      reply = Posts.Post |> Repo.get_by!(body: "Danke, Alice!") |> Repo.preload(:user)
      assert_redirect(view, Posts.path(reply))

      # The sidecar that carries it out to the other network.
      ref = Repo.get_by!(Vutuv.Posts.PostRemoteReply, post_id: reply.id)
      assert ref.note_id == note.id
      assert ref.inbox_uri == @inbox
    end
  end

  describe "a member who has not switched federation on" do
    setup do
      # A fresh conn: the outer setup already sent a response on its own, and a
      # second login through it would reconfigure an already-sent session.
      {conn, plain} =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> create_and_login_user(registration_attrs("plain"))

      {:ok, plain_conn: conn, plain: plain}
    end

    test "is told what the setting does and where it is", %{plain_conn: conn, note: note} do
      {:ok, _view, html} = live(conn, ~p"/system/fediverse/reply/#{note.id}")

      # Not a dead end: the capability is explained and the setting is one click
      # away.
      assert html =~ "Turn on Fediverse participation"
      assert html =~ ~s(href="/settings/fediverse")
      # And no composer, so there is nothing to fill in that could not be sent.
      refute html =~ "phx-submit=\"save\""
    end

    test "still sees the reply they cannot answer yet", %{plain_conn: conn, note: note} do
      {:ok, _view, html} = live(conn, ~p"/system/fediverse/reply/#{note.id}")
      assert html =~ "Sturdier than they look."
    end
  end

  describe "what is refused outright" do
    test "a reply addressed to the member alone", %{conn: conn, post: post} do
      private = note!(post, audience: "direct")

      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(conn, ~p"/system/fediverse/reply/#{private.id}")

      assert to == Posts.path(post)
      assert flash["error"] =~ "sent to you alone"
    end

    test "an unknown reply, without saying whether it ever existed", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               live(conn, ~p"/system/fediverse/reply/#{Vutuv.UUIDv7.generate()}")

      assert flash["error"] =~ "could not be found"
    end

    test "a private reply on somebody else's post is not even shown", %{post: post} do
      private = note!(post, audience: "direct")

      {other_conn, _stranger} =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> create_and_login_user(registration_attrs("nosy"))

      # The addressee alone may see it, so for anybody else it does not exist —
      # the same rule list_notes/2 enforces in the thread.
      assert {:error, {:redirect, %{to: "/"}}} =
               live(other_conn, ~p"/system/fediverse/reply/#{private.id}")

      assert Repo.get(Note, private.id)
      assert post
    end
  end

  describe "where the answer ends up in the conversation" do
    test "nested under the reply it answers, not beside it", %{
      conn: conn,
      user: user,
      post: post,
      note: note
    } do
      {:ok, answer} = Posts.create_remote_reply(user, note, %{"body" => "Danke, Alice!"})

      html = conn |> get(Posts.path(post)) |> html_response(200)

      # Underneath, the answer is an ordinary reply to `post`, so the forest would
      # have made it a *sibling* of the remote card. It belongs under it.
      assert html =~ "Danke, Alice!"
      assert has_children?(html, note), "the remote card should carry the answer as its child"
      assert answer.id
    end

    test "an ordinary reply to the same post stays beside the remote card", %{
      conn: conn,
      user: user,
      post: post,
      note: note
    } do
      {:ok, _plain} = Posts.create_reply(user, post, %{"body" => "Eine ganz normale Antwort."})

      html = conn |> get(Posts.path(post)) |> html_response(200)

      # Both are shown, and only an answer carrying the sidecar is moved under the
      # remote card — a plain reply to the same post stays its sibling.
      assert html =~ "Eine ganz normale Antwort."
      assert html =~ ~s(data-fediverse-reply="#{note.id}")
      refute has_children?(html, note)
    end
  end

  # Whether the thread drew the remote card as a node that has answers under it.
  # That connector span is rendered `:if={node.children != []}` immediately before
  # the card, so its presence right there is the rendered proof of nesting —
  # `[^>]*` cannot cross the span's own tag, so it cannot match some other node's
  # connector further up the page.
  defp has_children?(html, note) do
    marker = Regex.escape("top-9 h-[calc(100%-2.25rem)] w-0.5")

    pattern =
      Regex.compile!(
        marker <> ~s([^>]*>\\s*</span>\\s*<article data-fediverse-reply="#{note.id}"),
        "s"
      )

    html =~ pattern
  end

  describe "the Reply link on the card" do
    test "is offered on a public reply", %{conn: conn, post: post, note: note} do
      html = conn |> get(Posts.path(post)) |> html_response(200)
      assert html =~ "data-remote-reply-link=\"#{note.id}\""
    end

    test "is absent for a logged-out visitor", %{post: post} do
      html = build_conn() |> get(Posts.path(post)) |> html_response(200)
      refute html =~ "data-remote-reply-link"
    end
  end
end
