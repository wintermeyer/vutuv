defmodule VutuvWeb.BlockControllerTest do
  @moduledoc """
  The block flows: the profile-footer Block control (POST /blocks), the
  private blocked list at /blocks, and unblocking from either place.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Social

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, conn: conn, user: user, other: insert(:activated_user)}
  end

  test "POST /blocks blocks the member and returns to their profile", %{
    conn: conn,
    user: user,
    other: other
  } do
    insert(:follow, follower: user, followee: other)

    conn = post(conn, ~p"/blocks", block: %{"user_id" => other.id})

    assert redirected_to(conn) == ~p"/#{other}"
    assert Social.blocked_between?(user.id, other.id)
    assert Social.follow_id(user.id, other.id) == nil
  end

  test "GET /blocks lists blocked members with an unblock control", %{
    conn: conn,
    user: user,
    other: other
  } do
    {:ok, block} = Social.block_user(user, other)

    body = conn |> get(~p"/blocks") |> html_response(200)
    assert body =~ "@#{other.active_slug}"
    assert body =~ ~p"/blocks/#{block.id}"
  end

  test "DELETE /blocks/:id unblocks", %{conn: conn, user: user, other: other} do
    {:ok, block} = Social.block_user(user, other)

    conn = delete(conn, ~p"/blocks/#{block.id}")

    assert redirected_to(conn) == ~p"/blocks"
    refute Social.blocked_between?(user.id, other.id)
  end

  test "you cannot delete someone else's block", %{conn: conn, other: other} do
    third = insert(:activated_user)
    {:ok, block} = Social.block_user(third, other)

    assert_raise Ecto.NoResultsError, fn ->
      delete(conn, ~p"/blocks/#{block.id}")
    end
  end

  test "blocking yourself is refused", %{conn: conn, user: user} do
    conn = post(conn, ~p"/blocks", block: %{"user_id" => user.id})

    assert redirected_to(conn)
    refute Social.blocked_between?(user.id, user.id)
  end

  test "the blocked list requires a login" do
    conn = Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})
    conn = get(conn, ~p"/blocks")

    refute conn.status == 200
  end

  test "the profile shows Block to others and Unblock once blocked", %{
    conn: conn,
    user: user,
    other: other
  } do
    body = conn |> get(~p"/#{other}") |> html_response(200)
    assert body =~ "block-user"

    {:ok, block} = Social.block_user(user, other)

    body = conn |> get(~p"/#{other}") |> html_response(200)
    assert body =~ ~p"/blocks/#{block.id}"
  end
end
