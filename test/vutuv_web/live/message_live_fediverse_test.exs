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

  import Ecto.Query, only: [from: 2]
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

  # WebFinger answers the `self` link, the actor URL answers the document —
  # the two requests resolving an address really makes.
  defp stub_remote(fun) do
    Application.put_env(:vutuv, :fediverse_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp stub_account do
    stub_remote(fn conn ->
      {type, body} =
        case conn.request_path do
          "/.well-known/webfinger" ->
            {"application/jrd+json",
             %{
               "links" => [
                 %{
                   "rel" => "self",
                   "type" => "application/activity+json",
                   "href" => "https://social.example/users/them"
                 }
               ]
             }}

          _actor ->
            {"application/activity+json",
             %{
               "id" => "https://social.example/users/them",
               "type" => "Person",
               "preferredUsername" => "them",
               "name" => "Them",
               "inbox" => "https://social.example/users/them/inbox",
               "publicKey" => %{
                 "id" => "https://social.example/users/them#main-key",
                 "publicKeyPem" => "PEM"
               }
             }}
        end

      conn
      |> Plug.Conn.put_resp_content_type(type)
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)
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

    # The thread carries the words and the way back to the post — to the note
    # itself, not merely to the page it sits on: a conversation that has run a
    # while hangs under a post with a whole thread under it.
    [note] = Repo.all(Vutuv.Fediverse.Note)
    anchor = Fediverse.reply_anchor(note.id)

    {:ok, _view, html} = live(conn, ~p"/messages/#{entry.conversation.id}")
    assert html =~ "Frage lieber privat."
    assert html =~ "#{~p"/#{user.username}/posts/#{post.id}"}##{anchor}"

    # And the post view carries the way into the conversation, to the message,
    # with the anchor the link names really rendered.
    conn = get(conn, ~p"/#{user.username}/posts/#{post.id}")
    body = html_response(conn, 200)
    assert body =~ "data-note-conversation"
    assert body =~ ~s(id="#{anchor}")
    [message] = Repo.all(Message)
    assert body =~ "/messages/#{entry.conversation.id}#message-#{message.id}"
  end

  test "a sent private reply is linked to its own box under the post", %{
    conn: conn,
    user: user,
    account: account
  } do
    post = create_post!(user, %{body: "Mein Beitrag"})

    note =
      Repo.insert!(%Vutuv.Fediverse.Note{
        post_id: post.id,
        object_uri: "https://social.example/statuses/7",
        actor_uri: @actor,
        inbox_uri: @inbox,
        handle: "alice",
        display_name: "Alice Anders",
        content_text: "Frage lieber privat.",
        audience: "direct",
        received_at: DateTime.utc_now(:second),
        checked_at: DateTime.utc_now(:second),
        expires_at: DateTime.add(DateTime.utc_now(:second), 86_400)
      })

    {:ok, reply} = Fediverse.create_private_reply(user, note, %{body: "Klar, gern."})

    conversation = Repo.get_by!(Vutuv.Chat.Conversation, remote_account_id: account.id)
    {:ok, _view, html} = live(conn, ~p"/messages/#{conversation.id}")

    assert html =~
             "#{~p"/#{user.username}/posts/#{post.id}"}##{Fediverse.private_reply_anchor(reply.id)}"

    conn = get(conn, ~p"/#{user.username}/posts/#{post.id}")
    assert html_response(conn, 200) =~ ~s(id="#{Fediverse.private_reply_anchor(reply.id)}")
  end

  describe "the recipient finder" do
    test "finds members by first name, last name and both, in either order", %{conn: conn} do
      insert(:activated_user, first_name: "Jan", last_name: "Petersen", username: "janpetersen")
      {:ok, view, _html} = live(conn, ~p"/messages")

      # "@janpetersen" is the handle written the way the site shows it.
      for term <- ["Jan", "Petersen", "Jan Petersen", "Petersen Jan", "janpet", "@janpetersen"] do
        html = view |> form("#recipient-search-form", %{"q" => term}) |> render_change()
        assert html =~ "Jan Petersen", "searching for #{inspect(term)} found nobody"
      end

      # One keystroke never runs a %like% over the whole table.
      html = view |> form("#recipient-search-form", %{"q" => "J"}) |> render_change()
      refute html =~ "Jan Petersen"
    end

    test "an exact hit is not buried by the crowd it sits in", %{conn: conn} do
      # Searching "witt" on production matched 13 members somewhere in their
      # name; the alphabet by first name picked the first eight and Stephan
      # Witt — the one exact hit, handle `witt_s` — sat at position twelve.
      for first <- ~w(Anna Bernd Carla Dirk Emil Frieda Gustav Hanna Ida) do
        insert(:activated_user, first_name: first, last_name: "Wittmann")
      end

      exact =
        insert(:activated_user, first_name: "Stephan", last_name: "Witt", username: "witt_s")

      {:ok, view, _html} = live(conn, ~p"/messages")
      html = view |> form("#recipient-search-form", %{"q" => "witt"}) |> render_change()

      assert html =~ ~s(phx-value-id="#{exact.id}")
    end

    test "you are in your own results, greyed out and not writable", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/messages")

      html = view |> form("#recipient-search-form", %{"q" => user.username}) |> render_change()

      # Shown, because a search that silently omits you reads as broken — and
      # disabled, because writing to yourself is not a thing.
      assert html =~ ~s(phx-value-id="#{user.id}")
      assert has_element?(view, ~s(button[data-recipient-self][disabled]))
      assert html =~ "That&#39;s you"
    end

    test "our own address written out in full names the member, not another server",
         %{conn: conn} do
      stub_remote(fn _conn -> raise "this installation must not ask itself over the network" end)
      member = insert(:activated_user, first_name: "Ada", last_name: "Berg", username: "ada_b")

      {:ok, view, _html} = live(conn, ~p"/messages")

      # "localhost" is this installation in the test env, so `@ada_b@localhost`
      # is the same member the bare handle names — that is how every other
      # server writes a mention of them, and what a share button hands over.
      html =
        view |> form("#recipient-search-form", %{"q" => "@ada_b@localhost"}) |> render_change()

      assert html =~ ~s(phx-value-id="#{member.id}")
      refute html =~ "Look this address up"
    end

    test "the German page says what the field searches", %{conn: conn} do
      {:ok, _view, html} =
        conn
        |> recycle()
        |> Plug.Conn.put_req_header("accept-language", "de-DE,de")
        |> live(~p"/messages")

      assert html =~ "vutuv Mitglieder nach Vorname, Nachname, beidem oder Benutzernamen suchen."
      refute html =~ "Search vutuv members"
    end

    test "writing to a member opens the conversation", %{conn: conn, user: user} do
      other = insert(:activated_user, first_name: "Jana", last_name: "Brandt")
      {:ok, view, _html} = live(conn, ~p"/messages")

      view |> form("#recipient-search-form", %{"q" => "Jana"}) |> render_change()

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element(~s([phx-click="write-to-member"][phx-value-id="#{other.id}"]))
               |> render_click()

      conversation = Repo.get_by!(Vutuv.Chat.Conversation, user_a_id: min(user.id, other.id))
      assert to == "/messages/#{conversation.id}"
    end

    test "an account this installation already holds needs no request", %{
      conn: conn,
      account: account
    } do
      stub_remote(fn _conn -> raise "a stored account must not be looked up again" end)

      {:ok, view, _html} = live(conn, ~p"/messages")
      html = view |> form("#recipient-search-form", %{"q" => "alice"}) |> render_change()

      assert html =~ "Alice Anders"
      refute html =~ "Look this address up"

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element(~s([phx-click="write-to-account"][phx-value-id="#{account.id}"]))
               |> render_click()

      conversation = Repo.get_by!(Vutuv.Chat.Conversation, remote_account_id: account.id)
      assert to == "/messages/#{conversation.id}"
    end

    test "an unknown address is offered for lookup, and opens the conversation", %{
      conn: conn,
      user: user
    } do
      {:ok, _actor} = Fediverse.ensure_actor(user)
      stub_account()

      {:ok, view, _html} = live(conn, ~p"/messages")

      html =
        view
        |> form("#recipient-search-form", %{"q" => "@them@social.example"})
        |> render_change()

      assert html =~ "Look this address up"

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element(~s([phx-click="look-up-address"])) |> render_click()

      account = Repo.get_by!(RemoteAccount, actor_uri: "https://social.example/users/them")
      conversation = Repo.get_by!(Vutuv.Chat.Conversation, remote_account_id: account.id)
      assert to == "/messages/#{conversation.id}"
    end

    test "an address nothing answers for says so and opens no conversation", %{conn: conn} do
      stub_remote(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      {:ok, view, _html} = live(conn, ~p"/messages")

      view
      |> form("#recipient-search-form", %{"q" => "@nobody@social.example"})
      |> render_change()

      view |> element(~s([phx-click="look-up-address"])) |> render_click()

      assert has_element?(view, "#recipient-error")

      refute Repo.exists?(
               from(c in Vutuv.Chat.Conversation, where: not is_nil(c.remote_account_id))
             )
    end

    test "a member who does not federate searches vutuv alone", %{conn: conn, user: user} do
      user
      |> Ecto.Changeset.change(%{fediverse_followers?: false})
      |> Repo.update!()

      {:ok, view, html} = live(conn, ~p"/messages")
      assert html =~ "Switch Fediverse participation on"

      html =
        view
        |> form("#recipient-search-form", %{"q" => "@them@social.example"})
        |> render_change()

      refute html =~ "Look this address up"
      refute html =~ "Alice Anders"
    end
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
