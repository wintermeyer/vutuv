defmodule VutuvWeb.ConnectionControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Social

  describe "index (the vernetzt page)" do
    test "lists the member's mutual connections to everyone", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      owner = insert_activated_user(first_name: "Owner")
      friend = insert_activated_user(first_name: "Buddy")
      connect!(owner, friend)

      html = conn |> get(~p"/#{owner}/connections") |> html_response(200)

      assert html =~ "Buddy"
      # No request/accept machinery any more.
      refute html =~ "Connection requests"
    end

    test "the owner gets a Remove (unfollow) action linking the follow edge", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      friend = insert_activated_user(first_name: "Connie")
      connect!(me, friend)
      fid = Social.follow_id(me.id, friend.id)

      html = conn |> get(~p"/#{me}/connections") |> html_response(200)

      assert html =~ "Connie"
      assert html =~ ~p"/follows/#{fid}"
    end
  end

  describe "ending a connection" do
    test "unfollowing from the connections page ends the mutual follow", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      friend = insert_activated_user()
      connect!(me, friend)
      fid = Social.follow_id(me.id, friend.id)

      delete(conn, ~p"/follows/#{fid}")

      refute Social.connected?(me.id, friend.id)
      # Only my follow is dropped; their follow of me survives.
      refute Social.user_follows_user?(me.id, friend.id)
      assert Social.user_follows_user?(friend.id, me.id)
    end
  end

  describe "profile header control" do
    test "a logged-in visitor sees a Follow action, not a Connect one", %{conn: conn} do
      {conn, _me} = create_and_login_user(conn)
      other = insert_activated_user()

      html = conn |> get(~p"/#{other}") |> html_response(200)

      assert html =~ "Follow"
      # The old mutual-connection request control is gone.
      refute html =~ "/connections?"
    end

    test "once you follow them, the header offers a mute toggle", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      other = insert_activated_user()
      {:ok, follow} = Social.follow(me, other.id)

      html = conn |> get(~p"/#{other}") |> html_response(200)

      # The profile is a LiveView: mute is a phx-click menu item scoped to the
      # viewer's own follow id (the PUT /follows/:id/mute route still backs the
      # no-JS path).
      assert html =~ ~s(phx-click="toggle_mute")
      assert html =~ ~s(phx-value-id="#{follow.id}")
    end

    test "a mutual follow shows the connected (vernetzt) state via the ⇄ connector", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      other = insert_activated_user()
      connect!(me, other)

      html = conn |> get(~p"/#{other}") |> html_response(200)

      # The follow-only model marks "vernetzt" with both follow directions lit in
      # the segmented control plus a ⇄ connector, not a standalone "Connected"
      # word (mirrors the header_directional_follow_state tests in
      # user_controller_test).
      assert html =~ "Follows you"
      assert html =~ "You follow each other"
    end
  end

  describe "mute toggle (PUT /follows/:id/mute)" do
    test "mutes and unmutes the caller's own follow", %{conn: conn} do
      {conn, me} = create_and_login_user(conn)
      other = insert_activated_user()
      {:ok, follow} = Social.follow(me, other.id)

      put(conn, ~p"/follows/#{follow.id}/mute")
      assert Social.follow_edge(me.id, other.id).muted?

      put(conn, ~p"/follows/#{follow.id}/mute")
      refute Social.follow_edge(me.id, other.id).muted?
    end
  end
end
