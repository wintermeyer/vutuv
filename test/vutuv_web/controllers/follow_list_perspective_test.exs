defmodule VutuvWeb.FollowListPerspectiveTest do
  use VutuvWeb.ConnCase

  # "Following" (de "Folge ich") is written from the owner's perspective; a
  # visitor looking at someone else's profile or /following page must get the
  # third-person wording ("Follows" / de "Folgt") and never owner-voice empty
  # states ("It doesn't look like you're following anyone yet...").

  test "a visitor sees third-person labels on someone else's following page", %{conn: conn} do
    user = insert_activated_user(first_name: "Greta", last_name: "Gradient")

    html = get(conn, ~p"/#{user}/following") |> html_response(200)

    assert html =~ "Follows"
    refute html =~ "you&#39;re following"
  end

  test "the owner keeps the first-person label", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    html = get(conn, ~p"/#{user}/following") |> html_response(200)

    assert html =~ "Following"
  end

  test "a visitor sees a neutral empty state on someone else's followers page", %{conn: conn} do
    user = insert_activated_user()

    html = get(conn, ~p"/#{user}/followers") |> html_response(200)

    refute html =~ "If you want more followers"
  end

  test "the profile of someone else titles their following card in third person", %{conn: conn} do
    user = insert_activated_user(first_name: "Greta", last_name: "Gradient")
    other = insert_activated_user()
    follow!(user, other)

    html = get(conn, ~p"/#{user}") |> html_response(200)

    assert html =~ "Follows"
  end
end
