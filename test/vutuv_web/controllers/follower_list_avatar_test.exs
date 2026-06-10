defmodule VutuvWeb.FollowerListAvatarTest do
  use VutuvWeb.ConnCase

  # The shared user card list (followers / following / search results /
  # most-followed) used to put `Vutuv.Avatar.display_url/2` straight into an
  # <img>, so a user without a picture got the light-grey default-avatar SVG —
  # a bright white circle in dark mode. The list must render the <.avatar>
  # initials tile instead (the design-system rule for picture-less users).

  test "a follower without a picture gets an initials tile, not the grey default avatar",
       %{conn: conn} do
    user = insert_activated_user()
    follower = insert_activated_user(first_name: "Greta", last_name: "Tester")
    follow!(follower, user)

    html = conn |> get(~p"/#{user}/followers") |> html_response(200)

    assert html =~ ">GT<"
    # The "V" glyph path of Vutuv.Avatar's default-avatar data URI.
    refute html =~ "M88.96"
  end

  test "a follower with a picture keeps a real <img> avatar", %{conn: conn} do
    user = insert_activated_user()
    follower = insert_activated_user(avatar: "photo.jpg")
    follow!(follower, user)

    html = conn |> get(~p"/#{user}/followers") |> html_response(200)

    assert html =~ ~r/<img[^>]*data-avatar[^>]*avatars/
  end
end
