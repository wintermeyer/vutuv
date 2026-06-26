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

  test "list rows fall back to the headline when there is no work experience", %{conn: conn} do
    user = insert_activated_user()

    follower =
      insert_activated_user(
        first_name: "Hedda",
        last_name: "Headline",
        headline: "Designs **calm** interfaces"
      )

    follow!(follower, user)

    html = get(conn, ~p"/#{user}/followers") |> html_response(200)

    # Plain text, markdown markers stripped - this is a one-line list row.
    assert html =~ "Designs calm interfaces"
  end

  test "the profile of someone else titles their following card in third person", %{conn: conn} do
    user = insert_activated_user(first_name: "Greta", last_name: "Gradient")
    other = insert_activated_user()
    follow!(user, other)

    html = get(conn, ~p"/#{user}") |> html_response(200)

    assert html =~ "Follows"
  end

  test "the owner's own Following list offers a mute toggle per followed person", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    friend = insert_activated_user()
    {:ok, follow} = Vutuv.Social.follow(user, friend.id)

    html = get(conn, ~p"/#{user}/following") |> html_response(200)

    assert html =~ "/follows/#{follow.id}/mute"
  end

  test "a visitor gets no mute toggles on someone else's Following list", %{conn: conn} do
    {conn, _visitor} = create_and_login_user(conn)
    owner = insert_activated_user()
    friend = insert_activated_user()
    follow!(owner, friend)

    html = get(conn, ~p"/#{owner}/following") |> html_response(200)

    refute html =~ "/mute"
  end

  # The follow control in the list rows is the labeled text pill (the same one
  # the "who to follow" rail uses), not a bare icon glyph — so a row states
  # "Follow" / "Following" in words. (A member asked what the cryptic icons
  # meant; the answer was to label them.)
  test "the list shows the labeled follow pill, not a bare icon button", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    owner = insert_activated_user()

    # Someone the viewer already follows -> the row's pill reads "Following".
    followed = insert_activated_user(first_name: "Ada", last_name: "Followed")
    follow!(followed, owner)
    follow = follow!(viewer, followed)

    # Someone the viewer does not follow -> the row's pill is the "Follow" CTA.
    stranger = insert_activated_user(first_name: "Stan", last_name: "Stranger")
    follow!(stranger, owner)

    html = get(conn, ~p"/#{owner}/followers") |> html_response(200)

    # The old icon glyphs are gone; the pill carries visible labels instead.
    refute html =~ "icon--unfollow"
    refute html =~ "icon--follow"
    refute html =~ "button--icon"

    # The followed person's pill reads "Following" (with the hover "Unfollow"
    # label) and unfollows through its CSRF delete route.
    assert html =~ "Following"
    assert html =~ "Unfollow"
    assert html =~ ~s(/follows/#{follow.id})

    # The stranger's row carries the "Follow" call to action (a create POST).
    assert html =~ "/follows?follow"
    assert html =~ stranger.id
  end
end
