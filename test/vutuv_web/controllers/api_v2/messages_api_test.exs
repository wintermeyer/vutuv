defmodule VutuvWeb.ApiV2.MessagesApiTest do
  use VutuvWeb.ConnCase

  alias Vutuv.ApiAuth
  alias Vutuv.Chat

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()
    me = insert_activated_user()
    other = insert_activated_user()

    {:ok, token, _} = ApiAuth.create_pat(me, %{"name" => "t", "scopes" => ["messages:write"]})

    {:ok, other_token, _} =
      ApiAuth.create_pat(other, %{"name" => "t", "scopes" => ["messages:write"]})

    {:ok, conn: conn, me: me, other: other, token: token, other_token: other_token}
  end

  describe "POST /users/:slug/messages" do
    test "a body that embeds an image is a 422", %{conn: conn, other: other, token: token} do
      conn =
        json_post(conn, token, "/api/2.0/users/#{other.username}/messages", %{
          body: "hi ![x](https://evil.example/pixel.png)"
        })

      assert conn.status == 422
      assert json_response(conn, 422)["errors"]["body"]
    end

    test "messaging a follower lands directly; thread and list follow", %{
      conn: conn,
      me: me,
      other: other,
      token: token
    } do
      # other follows me, so my first message is no request.
      follow!(other, me)

      conn1 =
        json_post(conn, token, "/api/2.0/users/#{other.username}/messages", %{body: "Hi!"})

      sent = json_response(conn1, 201)
      assert %{"id" => id, "conversation_id" => conversation_id, "mine" => true} = sent
      assert is_binary(id)

      conn2 = get(authed(build_conn(), token), "/api/2.0/conversations")

      assert [%{"id" => ^conversation_id, "status" => "accepted", "unread" => 0}] =
               json_response(conn2, 200)["conversations"]

      conn3 =
        get(authed(build_conn(), token), "/api/2.0/conversations/#{conversation_id}/messages")

      assert [%{"body_markdown" => "Hi!", "mine" => true}] =
               json_response(conn3, 200)["messages"]
    end

    test "messaging a stranger opens a request the recipient can accept", %{
      conn: conn,
      other: other,
      token: token,
      other_token: other_token
    } do
      conn1 =
        json_post(conn, token, "/api/2.0/users/#{other.username}/messages", %{body: "Hello?"})

      %{"conversation_id" => conversation_id} = json_response(conn1, 201)

      # The recipient sees it under requests, not conversations.
      conn2 = get(authed(build_conn(), other_token), "/api/2.0/conversations")
      body = json_response(conn2, 200)
      assert body["conversations"] == []
      assert [%{"id" => ^conversation_id, "status" => "pending"}] = body["requests"]

      # A second request message is refused with a 409.
      conn3 =
        json_post(build_conn(), token, "/api/2.0/conversations/#{conversation_id}/messages", %{
          body: "Hello??"
        })

      assert conn3.status == 409

      # Accepting opens the thread.
      conn4 =
        post(
          authed(build_conn(), other_token),
          "/api/2.0/conversations/#{conversation_id}/accept"
        )

      assert json_response(conn4, 200)["status"] == "accepted"

      conn5 =
        json_post(build_conn(), token, "/api/2.0/conversations/#{conversation_id}/messages", %{
          body: "Thanks!"
        })

      assert json_response(conn5, 201)["id"]
    end

    test "a declined request stays indistinguishable from silence", %{
      conn: conn,
      me: me,
      other: other,
      token: token,
      other_token: other_token
    } do
      conn1 =
        json_post(conn, token, "/api/2.0/users/#{other.username}/messages", %{body: "Hi"})

      %{"conversation_id" => conversation_id} = json_response(conn1, 201)

      post(authed(build_conn(), other_token), "/api/2.0/conversations/#{conversation_id}/decline")

      # The sender's list still reads "pending" …
      conn2 = get(authed(build_conn(), token), "/api/2.0/conversations")
      assert [%{"status" => "pending"}] = json_response(conn2, 200)["conversations"]

      # … and further sends are quietly accepted (201, nothing persisted).
      conn3 =
        json_post(build_conn(), token, "/api/2.0/conversations/#{conversation_id}/messages", %{
          body: "Are you there?"
        })

      assert json_response(conn3, 201)
      page = Chat.messages_page(me, conversation_id)
      assert length(page.entries) == 1
    end

    test "a block answers with the opaque refusal", %{
      conn: conn,
      me: me,
      other: other,
      token: token
    } do
      {:ok, _} = Vutuv.Social.block_user(other, me)

      conn = json_post(conn, token, "/api/2.0/users/#{other.username}/messages", %{body: "x"})
      assert conn.status == 403
    end

    test "messaging yourself is a 422", %{conn: conn, me: me, token: token} do
      conn = json_post(conn, token, "/api/2.0/users/#{me.username}/messages", %{body: "x"})
      assert conn.status == 422
    end
  end

  describe "read state and scopes" do
    test "mark read clears the unread count", %{
      conn: conn,
      me: me,
      other: other,
      token: token,
      other_token: other_token
    } do
      follow!(me, other)

      conn1 =
        json_post(conn, other_token, "/api/2.0/users/#{me.username}/messages", %{body: "Ping"})

      %{"conversation_id" => conversation_id} = json_response(conn1, 201)

      conn2 = get(authed(build_conn(), token), "/api/2.0/conversations")
      assert [%{"unread" => 1}] = json_response(conn2, 200)["conversations"]

      conn3 = post(authed(build_conn(), token), "/api/2.0/conversations/#{conversation_id}/read")
      assert conn3.status == 204

      conn4 = get(authed(build_conn(), token), "/api/2.0/conversations")
      assert [%{"unread" => 0}] = json_response(conn4, 200)["conversations"]
    end

    test "messages:read cannot send", %{conn: conn, me: me, other: other} do
      {:ok, read_token, _} =
        ApiAuth.create_pat(me, %{"name" => "r", "scopes" => ["messages:read"]})

      conn1 = get(authed(conn, read_token), "/api/2.0/conversations")
      assert conn1.status == 200

      conn2 =
        json_post(build_conn(), read_token, "/api/2.0/users/#{other.username}/messages", %{
          body: "x"
        })

      assert conn2.status == 403
    end

    test "a non-participant cannot read a thread", %{conn: conn, other: other, token: token} do
      third = insert_activated_user()
      conversation = insert_conversation_between(other, third)

      conn = get(authed(conn, token), "/api/2.0/conversations/#{conversation.id}/messages")
      assert conn.status == 404
    end
  end

  describe "notifications" do
    test "lists derived events with unread count, mark read clears it", %{
      conn: conn,
      me: me,
      other: other
    } do
      {:ok, social_token, _} =
        ApiAuth.create_pat(me, %{"name" => "s", "scopes" => ["social:write"]})

      {:ok, _} = Vutuv.Social.follow(other, me.id)

      conn1 = get(authed(conn, social_token), "/api/2.0/notifications")
      body = json_response(conn1, 200)
      assert body["unread"] >= 1
      assert [%{"kind" => "follower", "actor_username" => slug} | _] = body["notifications"]
      assert slug == other.username

      conn2 = post(authed(build_conn(), social_token), "/api/2.0/notifications/read")
      assert conn2.status == 204

      conn3 = get(authed(build_conn(), social_token), "/api/2.0/notifications")
      assert json_response(conn3, 200)["unread"] == 0
    end
  end
end
