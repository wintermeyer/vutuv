defmodule VutuvWeb.UserSaveControllerTest do
  @moduledoc """
  The profile-header "bookmark / like this member" toggles (issue #792): a
  private, silent save with no follow or connection prerequisite. POST to save,
  DELETE /:id (the target member's id) to remove.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Social

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, conn: conn, user: user, other: insert(:activated_user)}
  end

  test "POST /user_bookmarks saves the member, no follow/connection created", %{
    conn: conn,
    user: user,
    other: other
  } do
    conn = post(conn, ~p"/user_bookmarks", user_bookmark: %{"target_user_id" => other.id})

    assert redirected_to(conn) == ~p"/#{other}"
    assert %{bookmarked?: true} = Social.user_saved_flags(user, other)
    refute Social.user_follows_user?(user.id, other.id)
  end

  test "DELETE /user_bookmarks/:id removes the bookmark", %{conn: conn, user: user, other: other} do
    :ok = Social.bookmark_user(user, other)

    conn = delete(conn, ~p"/user_bookmarks/#{other.id}")

    assert redirected_to(conn)
    assert %{bookmarked?: false} = Social.user_saved_flags(user, other)
  end

  test "POST /user_likes likes the member", %{conn: conn, user: user, other: other} do
    conn = post(conn, ~p"/user_likes", user_like: %{"target_user_id" => other.id})

    assert redirected_to(conn) == ~p"/#{other}"
    assert %{liked?: true} = Social.user_saved_flags(user, other)
  end

  test "DELETE /user_likes/:id removes the like", %{conn: conn, user: user, other: other} do
    :ok = Social.like_user(user, other)

    conn = delete(conn, ~p"/user_likes/#{other.id}")

    assert redirected_to(conn)
    assert %{liked?: false} = Social.user_saved_flags(user, other)
  end

  test "the profile renders the like and bookmark toggles for a logged-in visitor", %{
    conn: conn,
    other: other
  } do
    body = conn |> get(~p"/#{other}") |> html_response(200)

    assert body =~ ~p"/user_bookmarks?#{[user_bookmark: %{target_user_id: other.id}]}"
    assert body =~ ~p"/user_likes?#{[user_like: %{target_user_id: other.id}]}"
  end

  test "saving across a block is refused, leaving no save", %{
    conn: conn,
    user: user,
    other: other
  } do
    {:ok, _} = Social.block_user(user, other)

    conn = post(conn, ~p"/user_likes", user_like: %{"target_user_id" => other.id})

    assert redirected_to(conn)
    assert %{liked?: false} = Social.user_saved_flags(user, other)
  end

  test "a logged-out visitor sees no save controls and cannot post", %{other: other} do
    body = build_conn() |> get(~p"/#{other}") |> html_response(200)
    refute body =~ "/user_bookmarks?"
    refute body =~ "/user_likes?"

    # RequireLoginOr404 guards the action.
    assert build_conn()
           |> post(~p"/user_likes", user_like: %{"target_user_id" => other.id})
           |> response(404)
  end
end
