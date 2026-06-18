defmodule VutuvWeb.ConnectionControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Social
  alias Vutuv.Social.Connection

  describe "create (request a connection)" do
    test "sends a pending request to another user", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      other = insert_activated_user()

      conn = post(conn, ~p"/connections", connection: %{user_id: other.id})

      assert redirected_to(conn)
      assert Repo.aggregate(Connection, :count) == 1
      assert %{status: :pending_sent} = Social.connection_state(me, other)
    end

    test "a malformed user_id is a graceful error, not a 500", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)

      conn = post(conn, ~p"/connections", connection: %{user_id: "not-a-uuid"})

      assert redirected_to(conn)
      assert Repo.aggregate(Connection, :count) == 0
    end
  end

  describe "accept / decline" do
    test "the recipient accepts, materializing the follow both ways", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      other = insert_activated_user()
      {:ok, c} = Social.request_connection(other, me)

      post(conn, ~p"/connections/#{c.id}/accept")

      assert Social.connected?(me.id, other.id)
      assert Social.user_follows_user?(me.id, other.id)
      assert Social.user_follows_user?(other.id, me.id)
    end

    test "the recipient declines (silently)", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      other = insert_activated_user()
      {:ok, c} = Social.request_connection(other, me)

      post(conn, ~p"/connections/#{c.id}/decline")

      refute Social.connected?(me.id, other.id)
      assert %{status: :none} = Social.connection_state(me, other)
    end
  end

  describe "delete (disconnect / withdraw)" do
    test "disconnecting drops the connection but keeps the follow edges", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      other = insert_activated_user()
      c = connect!(me, other)

      delete(conn, ~p"/connections/#{c.id}")

      refute Social.connected?(me.id, other.id)
      assert Social.user_follows_user?(me.id, other.id)
    end
  end

  describe "index (the connections page)" do
    test "the owner sees their incoming requests and accepted connections", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      friend = insert_activated_user(first_name: "Connie")
      requester = insert_activated_user(first_name: "Reqqy")
      connect!(me, friend)
      {:ok, _} = Social.request_connection(requester, me)

      html = conn |> get(~p"/#{me}/connections") |> html_response(200)

      assert html =~ "Connie"
      assert html =~ "Reqqy"
      assert html =~ "Connection requests"
    end

    test "a visitor sees only the accepted connections, not the owner's requests", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      owner = insert_activated_user(first_name: "Owner")
      friend = insert_activated_user(first_name: "Buddy")
      connect!(owner, friend)
      requester = insert_activated_user()
      {:ok, _} = Social.request_connection(requester, owner)

      html = conn |> get(~p"/#{owner}/connections") |> html_response(200)

      assert html =~ "Buddy"
      refute html =~ "Connection requests"
    end
  end

  describe "profile header control" do
    test "a logged-in visitor sees a Connect action on another profile", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      other = insert_activated_user()

      html = conn |> get(~p"/#{other}") |> html_response(200)

      assert html =~ "Connect"
      assert html =~ "/connections?"
    end
  end
end
