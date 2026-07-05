defmodule VutuvWeb.MessageLiveTest do
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Chat

  # A second browser session for another member.
  defp login_other_user(name \\ "Other") do
    conn = Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})

    create_and_login_user(conn, %{
      "emails" => %{"0" => %{"value" => "#{String.downcase(name)}@example.com"}},
      "first_name" => name,
      "tag_list" => @registration_tags
    })
  end

  describe "authentication and authorization" do
    test "redirects logged-out visitors to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/messages")
    end

    test "an unknown conversation id redirects to the conversation list", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      assert {:error, {:live_redirect, %{to: "/messages"}}} =
               live(conn, ~p"/messages/#{Vutuv.UUIDv7.generate()}")
    end

    test "someone else's conversation redirects to the conversation list", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      conversation = insert_conversation_between(insert_activated_user(), insert_activated_user())

      assert {:error, {:live_redirect, %{to: "/messages"}}} =
               live(conn, ~p"/messages/#{conversation.id}")
    end
  end

  describe "conversation list" do
    test "shows real conversations with the other member's name and preview", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      other = insert_activated_user(first_name: "Berta", last_name: "Beispiel")
      conversation = insert_conversation_between(me, other)
      {:ok, _} = Chat.send_message(other, conversation.id, "Hello there")

      {:ok, _view, html} = live(conn, ~p"/messages")

      assert html =~ "Berta Beispiel"
      assert html =~ "Hello there"
    end

    test "shows an empty state without any conversations", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)

      {:ok, _view, html} = live(conn, ~p"/messages")

      assert html =~ "No conversations yet"
    end
  end

  describe "sending" do
    test "a sent message is persisted and survives a reload", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      conversation = insert_conversation_between(me, insert_activated_user())

      {:ok, view, _} = live(conn, ~p"/messages/#{conversation.id}")

      view
      |> form("#message-form", message: %{body: "For the record"})
      |> render_submit()

      # Let the sender's own echo broadcast finish before the test exits.
      _ = :sys.get_state(view.pid)

      {:ok, _view, html} = live(conn, ~p"/messages/#{conversation.id}")
      assert html =~ "For the record"
    end

    test "the composer is a multi-line textarea, not a single-line input", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      conversation = insert_conversation_between(me, insert_activated_user())

      {:ok, view, _} = live(conn, ~p"/messages/#{conversation.id}")

      # Issue #903: a single-line <input> made long/multi-line messages
      # impossible. The composer must be a <textarea>.
      assert has_element?(view, "textarea[name='message[body]']")
      refute has_element?(view, "input[name='message[body]']")
    end

    test "a multi-line message keeps its line breaks", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      conversation = insert_conversation_between(me, insert_activated_user())

      {:ok, view, _} = live(conn, ~p"/messages/#{conversation.id}")

      view
      |> form("#message-form", message: %{body: "First line\nSecond line"})
      |> render_submit()

      _ = :sys.get_state(view.pid)

      {:ok, _view, html} = live(conn, ~p"/messages/#{conversation.id}")
      assert html =~ "First line"
      assert html =~ "Second line"
      # Earmark renders a lone newline as a <br> (breaks: true), so the two
      # lines stay visually separate inside the bubble.
      assert html =~ "<br"
    end

    test "the composer starts at two rows and drops the helper line", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      conversation = insert_conversation_between(me, insert_activated_user())

      {:ok, view, _} = live(conn, ~p"/messages/#{conversation.id}")

      # The composer opens at two rows so a reply has room to breathe (it still
      # autogrows past that as you type).
      assert has_element?(view, "#message-body[rows='2']")

      # The Markdown / Ctrl+Enter helper line was removed to keep the composer
      # compact; both features still work, they are just no longer spelled out.
      refute has_element?(view, "#send-shortcut-key")
    end

    test "a deleted message disappears live from open threads", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      {_other_conn, other} = login_other_user()
      conversation = insert_conversation_between(me, other)
      {:ok, message} = Vutuv.Chat.send_message(other, conversation.id, "to be removed")

      {:ok, view, _} = live(conn, ~p"/messages/#{conversation.id}")
      assert has_element?(view, "#message-#{message.id}")

      # The only caller is moderation deleting reported content: the bubble must
      # leave open threads, not linger until reload.
      {:ok, _} = Vutuv.Chat.delete_message(other, message)
      _ = :sys.get_state(view.pid)

      refute has_element?(view, "#message-#{message.id}")
    end

    test "a message appears live in the other member's session", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      {other_conn, other} = login_other_user()
      conversation = insert_conversation_between(me, other)

      {:ok, sender, _} = live(conn, ~p"/messages/#{conversation.id}")
      {:ok, receiver, _} = live(other_conn, ~p"/messages/#{conversation.id}")

      sender
      |> form("#message-form", message: %{body: "Real-time hello"})
      |> render_submit()

      # The broadcast to the other session is async; force it to be processed
      # (and the sender's own echo too, so nothing runs after the test exits).
      _ = :sys.get_state(receiver.pid)
      _ = :sys.get_state(sender.pid)

      assert render(receiver) =~ "Real-time hello"
    end

    test "a new message in the open thread updates its sidebar preview and floats it to the top",
         %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      {_alpha_conn, alpha} = login_other_user("Alpha")
      {_beta_conn, beta} = login_other_user("Beta")

      # Two accepted conversations. Beta's is the most recent, so it sits on top
      # of the sidebar; Alpha's is older and below it.
      conv_alpha = insert_conversation_between(me, alpha)
      {:ok, _} = Chat.send_message(alpha, conv_alpha.id, "alpha original")
      conv_beta = insert_conversation_between(me, beta)
      {:ok, _} = Chat.send_message(beta, conv_beta.id, "beta latest")

      # Open Alpha's thread, then Alpha sends a fresh message into it.
      {:ok, view, _} = live(conn, ~p"/messages/#{conv_alpha.id}")
      {:ok, _} = Chat.send_message(alpha, conv_alpha.id, "alpha bumped")
      _ = :sys.get_state(view.pid)

      html = render(view)

      # The sidebar preview reflects the new message (the in-memory bump, not a
      # stale reload)...
      assert html =~ "alpha bumped"
      # ...and Alpha's conversation has floated above Beta's in the sidebar (the
      # sidebar renders before the open thread, so the first occurrence of each
      # preview is its sidebar row).
      assert at_index(html, "alpha bumped") < at_index(html, "beta latest")
    end

    defp at_index(html, needle) do
      {index, _length} = :binary.match(html, needle)
      index
    end

    test "messages render markdown safely with a timestamp", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      conversation = insert_conversation_between(me, insert_activated_user())

      {:ok, sender, _} = live(conn, ~p"/messages/#{conversation.id}")

      sender
      |> form("#message-form",
        message: %{
          body:
            "**bold** <script>alert(1)</script> https://example.com/a/very/long/path/that/keeps/going/and/going"
        }
      )
      |> render_submit()

      # The echo comes back to the sender via PubSub; force it to be processed.
      _ = :sys.get_state(sender.pid)
      html = render(sender)

      assert html =~ "<strong>bold</strong>"
      refute html =~ "<script"
      # bare URL became a truncated link
      assert html =~ ~s(href="https://example.com/a/very/long/path/that/keeps/going/and/going")
      assert html =~ "…"
      # timestamp is rendered
      assert html =~ "<time"
    end

    test "typing in one session shows the animated typing bubble in the other", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      {other_conn, other} = login_other_user()
      conversation = insert_conversation_between(me, other)

      {:ok, typer, _} = live(conn, ~p"/messages/#{conversation.id}")
      {:ok, watcher, _} = live(other_conn, ~p"/messages/#{conversation.id}")

      typer
      |> form("#message-form", message: %{body: "typ"})
      |> render_change()

      _ = :sys.get_state(watcher.pid)

      assert has_element?(watcher, "#typing-bubble")
      assert render(watcher) =~ "is typing"
    end
  end

  describe "message requests" do
    test "a stranger's message lands as a request the recipient can accept", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      stranger = insert_activated_user(first_name: "Sam", last_name: "Stranger")
      conversation = insert_conversation_between(stranger, me, status: "pending")
      {:ok, _} = Chat.send_message(stranger, conversation.id, "May I?")

      {:ok, view, html} = live(conn, ~p"/messages")

      assert html =~ "Sam Stranger"
      assert html =~ "May I?"
      assert has_element?(view, "#requests")

      view |> element("#requests button", "Accept") |> render_click()

      # Accepted: out of the requests block, into the conversation list.
      refute has_element?(view, "#requests")
      assert render(view) =~ "Sam Stranger"
      assert Vutuv.Repo.get!(Vutuv.Chat.Conversation, conversation.id).status == "accepted"
    end

    test "declining silently removes the request", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      stranger = insert_activated_user()
      conversation = insert_conversation_between(stranger, me, status: "pending")
      {:ok, _} = Chat.send_message(stranger, conversation.id, "May I?")

      {:ok, view, _} = live(conn, ~p"/messages")

      view |> element("#requests button", "Decline") |> render_click()

      refute has_element?(view, "#requests")
      refute render(view) =~ "May I?"
      assert Chat.list_requests(me) == []
    end

    test "the requester sees a waiting hint instead of the composer", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      other = insert_activated_user()
      conversation = insert_conversation_between(me, other, status: "pending", initiator: me)
      {:ok, _} = Chat.send_message(me, conversation.id, "hello-out-there")

      {:ok, view, html} = live(conn, ~p"/messages/#{conversation.id}")

      refute has_element?(view, "#message-form")
      assert html =~ "hello-out-there"
    end

    test "accepting live-swaps the requester's open thread to a composer", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      {other_conn, other} = login_other_user()
      conversation = insert_conversation_between(me, other, status: "pending", initiator: me)
      {:ok, _} = Chat.send_message(me, conversation.id, "May I?")

      # The requester sits in the open thread with the waiting hint, no composer.
      {:ok, requester, _} = live(conn, ~p"/messages/#{conversation.id}")
      refute has_element?(requester, "#message-form")

      # The recipient accepts from their own session.
      {:ok, recipient, _} = live(other_conn, ~p"/messages")
      recipient |> element("#requests button", "Accept") |> render_click()

      # The accept broadcast reaches the requester's open thread; flush it.
      _ = :sys.get_state(requester.pid)

      assert has_element?(requester, "#message-form")
    end

    test "the recipient of a request gets a composer; replying accepts", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      stranger = insert_activated_user()
      conversation = insert_conversation_between(stranger, me, status: "pending")
      {:ok, _} = Chat.send_message(stranger, conversation.id, "May I?")

      {:ok, view, _} = live(conn, ~p"/messages/#{conversation.id}")

      view
      |> form("#message-form", message: %{body: "Sure!"})
      |> render_submit()

      _ = :sys.get_state(view.pid)

      assert Vutuv.Repo.get!(Vutuv.Chat.Conversation, conversation.id).status == "accepted"
    end
  end

  describe "blocking from a thread" do
    test "the thread offers a Block action for the other member", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      other = insert_activated_user(first_name: "Otto", last_name: "Other")
      conversation = insert_conversation_between(me, other)

      {:ok, view, _} = live(conn, ~p"/messages/#{conversation.id}")

      assert has_element?(view, "#thread-menu")
      assert has_element?(view, "#block-from-thread")
    end

    test "blocking from the thread severs ties, freezes it, and returns to the list", %{
      conn: conn
    } do
      {conn, me} = create_and_login_user(conn)
      other = insert_activated_user()
      conversation = insert_conversation_between(me, other)
      insert(:follow, follower: me, followee: other)

      {:ok, view, _} = live(conn, ~p"/messages/#{conversation.id}")

      assert {:error, {:live_redirect, %{to: "/messages"}}} =
               view |> element("#block-from-thread") |> render_click()

      assert Vutuv.Social.blocked_between?(me.id, other.id)
      assert Vutuv.Social.follow_id(me.id, other.id) == nil
      assert Vutuv.Repo.get!(Vutuv.Chat.Conversation, conversation.id).frozen_at
    end
  end

  describe "thread pagination" do
    test "older messages load on demand", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      other = insert_activated_user()
      conversation = insert_conversation_between(me, other)

      for i <- 1..35 do
        at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), i - 40)

        insert(:message,
          conversation: conversation,
          sender: other,
          body: "numbered message #{String.pad_leading("#{i}", 2, "0")}",
          inserted_at: at
        )
      end

      {:ok, view, html} = live(conn, ~p"/messages/#{conversation.id}")

      assert html =~ "numbered message 35"
      refute html =~ "numbered message 05"
      assert has_element?(view, "#load-older")

      view |> element("#load-older") |> render_click()

      html = render(view)
      assert html =~ "numbered message 01"
      refute has_element?(view, "#load-older")
    end
  end

  describe "new conversation entry" do
    test "/messages/with/:slug opens the conversation with that member", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      other = insert_activated_user()

      assert {:error, {:live_redirect, %{to: "/messages/" <> id}}} =
               live(conn, ~p"/messages/with/#{other.username}")

      assert Vutuv.Repo.get!(Vutuv.Chat.Conversation, id)
    end

    test "an unknown slug redirects to the conversation list", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)

      assert {:error, {:live_redirect, %{to: "/messages"}}} =
               live(conn, ~p"/messages/with/nobody-here")
    end

    test "the profile Message button points at the conversation-with route", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      other = insert_activated_user()

      html = conn |> get(~p"/#{other.username}") |> html_response(200)

      assert html =~ ~s(href="/messages/with/#{other.username}")
    end
  end

  describe "mobile layout" do
    test "the index shows the list full-width; a thread shows a back link", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      conversation = insert_conversation_between(me, insert_activated_user())

      {:ok, index_view, _} = live(conn, ~p"/messages")
      # No active conversation: the list is visible on mobile (not hidden).
      refute has_element?(index_view, "aside.hidden")

      {:ok, show_view, _} = live(conn, ~p"/messages/#{conversation.id}")
      assert has_element?(show_view, "aside.hidden")
      assert has_element?(show_view, "#back-to-list")
    end

    test "the chat fills the viewport as a full-screen mobile layout", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      conversation = insert_conversation_between(me, insert_activated_user())

      {:ok, view, _} = live(conn, ~p"/messages/#{conversation.id}")

      # On phones the thread fills the whole viewport between the sticky top bar
      # and the bottom tab bar (100dvh-8rem), with the composer sitting in-flow
      # at the bottom — nothing extra pinned. The data-chat-fullscreen marker
      # drives the components.css rule that hides the site footer on mobile so it
      # does not add a second scroll below the thread.
      assert has_element?(view, "#messages[data-chat-fullscreen].h-\\[calc\\(100dvh-8rem\\)\\]")

      # The composer is an ordinary bottom-of-flow form, not a separately fixed
      # dock (that approach was dropped) — the thread just scrolls above it.
      assert has_element?(view, "#message-thread.flex-1.overflow-y-auto")
      assert has_element?(view, "#message-form")
      refute has_element?(view, "#composer-dock")
    end
  end

  describe "presence" do
    test "a lone viewer sees no online indicator", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      conversation = insert_conversation_between(me, insert_activated_user())

      {:ok, view, _} = live(conn, ~p"/messages/#{conversation.id}")

      # The thread-header "Online" status for the *other* party — not the shell's
      # own-avatar dot label, which also reads "Online".
      refute has_element?(view, "#other-online")
    end

    test "the other member on the page shows as online", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      {other_conn, other} = login_other_user()
      conversation = insert_conversation_between(me, other)

      {:ok, view, _} = live(conn, ~p"/messages/#{conversation.id}")
      {:ok, _other_view, _} = live(other_conn, ~p"/messages")

      # The presence join reaches the first view asynchronously; flush it.
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#other-online")
    end
  end
end
