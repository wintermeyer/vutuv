defmodule VutuvWeb.SettingsFollowedTagsTest do
  use VutuvWeb.ConnCase, async: true

  # The /settings/followed_tags management list and its conditional settings-hub
  # row (issue #872), mirroring the saved-searches pattern: the row joins the hub
  # only once the member follows at least one tag.

  alias Vutuv.Tags

  test "lists the member's followed tags with an unfollow control", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    tag = insert(:tag, name: "Elixir", slug: "elixir")
    Tags.follow_tag(user, tag)

    html = conn |> get(~p"/settings/followed_tags") |> html_response(200)
    assert html =~ "Elixir"
    assert html =~ ~s(href="/tag_follows/#{tag.id}")
  end

  test "the settings hub shows the row only once a tag is followed", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    html = conn |> get(~p"/settings") |> html_response(200)
    refute html =~ "Tags you follow"

    tag = insert(:tag, name: "Elixir", slug: "elixir")
    Tags.follow_tag(user, tag)

    html = conn |> recycle() |> get(~p"/settings") |> html_response(200)
    assert html =~ "Tags you follow"
    assert html =~ "/settings/followed_tags"
  end
end
