defmodule VutuvWeb.MessageLiveFediverseTest do
  @moduledoc """
  The messages page with an account on another network on the other side.

  The page was built for two local identity kinds and reads a party's columns
  in a dozen places, so this drives the whole surface rather than one function:
  the sidebar row, the thread, the privacy line, sending, and the two links
  that join this view to the post view.

  `async: false` — the Fediverse switches are application env.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Chat
  alias Vutuv.Chat.Message
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias VutuvWeb.Fediverse.Docs

  @actor "https://social.example/users/alice"
  @inbox "https://social.example/users/alice/inbox"

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()
    {conn, user} = create_and_login_user(conn)

    # Reload: the login helper hands back the row as it was BEFORE the PIN
    # confirmed the address, and `Fediverse.federated?/1` reads
    # `email_confirmed?` off the struct it is given.
    user =
      user
      |> Repo.reload!()
      |> Ecto.Changeset.change(%{fediverse_followers?: true, fediverse_replies?: true})
      |> Repo.update!()

    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: @actor,
        inbox_uri: @inbox,
        host: "social.example",
        handle: "alice",
        name: "Alice Anders"
      })

    {:ok, conn: conn, user: user, account: account}
  end

  test "the account page's Message button opens the conversation", %{
    conn: conn,
    user: user,
    account: account
  } do
    {:ok, view, html} = live(conn, ~p"/system/fediverse/account/#{account.id}")
    assert html =~ "Message"

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#message-account") |> render_click()

    # The button lands on the find-or-create route, which itself navigates on
    # to the thread it opened.
    assert to == "/messages/fediverse/#{account.id}"
    assert {:error, {:live_redirect, %{to: thread}}} = live(conn, to)

    assert [entry] = Chat.list_conversations(user)
    assert entry.other.id == account.id
    assert thread == "/messages/#{entry.conversation.id}"

    {:ok, _view, html} = live(conn, thread)
    assert html =~ "Alice Anders"
    # The one thing a member has to be told before writing.
    assert html =~ "social.example"
    assert html =~ "end-to-end"
  end

  test "writing sends it into the Fediverse and shows it in the thread", %{
    conn: conn,
    user: user,
    account: account
  } do
    {:ok, conversation} = Chat.fediverse_conversation(user, account, :member)
    {:ok, view, _html} = live(conn, ~p"/messages/#{conversation.id}")

    view
    |> form("#message-form", message: %{body: "Hallo Alice, hast du kurz Zeit?"})
    |> render_submit()

    # Let the sender's own echo broadcast finish, then read the thread back.
    _ = :sys.get_state(view.pid)
    {:ok, _view, html} = live(conn, ~p"/messages/#{conversation.id}")
    assert html =~ "Hallo Alice"

    assert [%Message{} = message] = Repo.all(Message)
    assert message.sender_id == user.id
    assert message.private_message_id

    assert [delivery] = Repo.all(Fediverse.Delivery)
    assert delivery.inbox_uri == @inbox
  end

  test "an incoming private answer is a conversation and links back to the post", %{
    conn: conn,
    user: user,
    account: account
  } do
    post = create_post!(user, %{body: "Mein Beitrag"})

    :ok =
      Fediverse.record_reply(
        user,
        %{
          "id" => "https://social.example/statuses/1#create",
          "type" => "Create",
          "actor" => @actor,
          "to" => [Docs.actor_url(user)],
          "object" => %{
            "id" => "https://social.example/statuses/1",
            "type" => "Note",
            "attributedTo" => @actor,
            "inReplyTo" => Docs.note_url(user, post.id),
            "content" => "<p>Frage lieber privat.</p>",
            "to" => [Docs.actor_url(user)]
          }
        },
        %{uri: @actor, handle: "alice", name: "Alice Anders", inbox: @inbox}
      )

    # The request is in the sidebar and can be accepted.
    {:ok, view, html} = live(conn, ~p"/messages")
    assert html =~ "Alice Anders"
    assert html =~ "Requests" or html =~ "Anfragen"

    [entry] = Chat.list_requests(user)

    render_click(
      element(view, "button[phx-value-id='#{entry.conversation.id}'][phx-click='accept']")
    )

    # The thread carries the words and the way back to the post.
    {:ok, _view, html} = live(conn, ~p"/messages/#{entry.conversation.id}")
    assert html =~ "Frage lieber privat."
    assert html =~ ~p"/#{user.username}/posts/#{post.id}"

    # And the post view carries the way into the conversation.
    conn = get(conn, ~p"/#{user.username}/posts/#{post.id}")
    body = html_response(conn, 200)
    assert body =~ "data-note-conversation"
    assert body =~ "/messages/#{entry.conversation.id}"
  end

  test "no file button and no block menu for an account on another network", %{
    conn: conn,
    user: user,
    account: account
  } do
    {:ok, conversation} = Chat.fediverse_conversation(user, account, :member)
    {:ok, view, _html} = live(conn, ~p"/messages/#{conversation.id}")

    refute has_element?(view, "#thread-menu")
    refute has_element?(view, "label[for='attachments']")
  end
end
