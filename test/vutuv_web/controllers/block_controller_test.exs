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

  test "GET /blocks offers a form to block a new member by handle", %{conn: conn} do
    body = conn |> get(~p"/blocks") |> html_response(200)
    assert body =~ "block-someone-form"
    assert body =~ "block[handle]"
  end

  test "POST /blocks with a handle blocks the member and returns to the blocked list", %{
    conn: conn,
    user: user,
    other: other
  } do
    # A leading "@" and odd casing both have to resolve to the active slug.
    conn = post(conn, ~p"/blocks", block: %{"handle" => "@#{String.upcase(other.active_slug)}"})

    assert redirected_to(conn) == ~p"/blocks"
    assert Social.blocked_between?(user.id, other.id)
  end

  test "POST /blocks with an unknown handle blocks nobody", %{conn: conn, user: user} do
    conn = post(conn, ~p"/blocks", block: %{"handle" => "no-such-member"})

    assert redirected_to(conn) == ~p"/blocks"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no-such-member"
    assert Social.list_blocked(user) == []
  end

  test "POST /blocks with a blank handle blocks nobody", %{conn: conn, user: user} do
    conn = post(conn, ~p"/blocks", block: %{"handle" => "  "})

    assert redirected_to(conn) == ~p"/blocks"
    assert Social.list_blocked(user) == []
  end

  test "POST /blocks refuses blocking yourself by handle", %{conn: conn, user: user} do
    conn = post(conn, ~p"/blocks", block: %{"handle" => "@#{user.active_slug}"})

    assert redirected_to(conn) == ~p"/blocks"
    refute Social.blocked_between?(user.id, user.id)
  end

  test "POST /blocks with an already-blocked handle stays idempotent", %{
    conn: conn,
    user: user,
    other: other
  } do
    {:ok, _block} = Social.block_user(user, other)

    conn = post(conn, ~p"/blocks", block: %{"handle" => other.active_slug})

    assert redirected_to(conn) == ~p"/blocks"
    assert length(Social.list_blocked(user)) == 1
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

  test "a malformed user_id is a graceful error, not a 500", %{conn: conn} do
    conn = post(conn, ~p"/blocks", block: %{"user_id" => "not-a-uuid"})

    assert redirected_to(conn) == ~p"/"
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
