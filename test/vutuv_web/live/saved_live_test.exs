defmodule VutuvWeb.SavedLiveTest do
  @moduledoc """
  The /likes and /bookmarks LiveView drops a card live when the post it shows is
  deleted. A liker/bookmarker need not follow the author, so the per-post topic
  (which every shown card subscribes to) is the only signal that reaches them —
  the feed's follower broadcast does not.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Posts

  defp other_user(attrs \\ []), do: insert(:user, Keyword.merge([email_confirmed?: true], attrs))

  test "a liked post is removed live when its author deletes it", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    author = other_user()
    post = create_post!(author, %{body: "liked then gone"})
    :ok = Posts.like_post(user, post)

    {:ok, view, html} = live(conn, ~p"/likes")
    assert html =~ "liked then gone"

    {:ok, _} = Posts.delete_post(post)
    _ = :sys.get_state(view.pid)
    refute render(view) =~ "liked then gone"
  end

  test "a bookmarked post is removed live when its author's account is deleted", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    author = other_user()
    post = create_post!(author, %{body: "saved then gone"})
    :ok = Posts.bookmark_post(user, post)

    {:ok, view, html} = live(conn, ~p"/bookmarks")
    assert html =~ "saved then gone"

    {:ok, _} = Vutuv.Accounts.delete_user(author)
    _ = :sys.get_state(view.pid)
    refute render(view) =~ "saved then gone"
  end

  test "the People sub-tab lists bookmarked members; search filters them", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    keeper = other_user(first_name: "Bernadette", last_name: "Keeper")
    other = other_user(first_name: "Conrad", last_name: "Other")
    :ok = Vutuv.Social.bookmark_user(user, keeper)
    :ok = Vutuv.Social.bookmark_user(user, other)

    {:ok, view, _html} = live(conn, ~p"/bookmarks?tab=people")
    assert has_element?(view, "#saved-people li", "Bernadette")
    assert has_element?(view, "#saved-people li", "Conrad")

    # The shared search box filters the people list server-side.
    view |> form("#saved-filter") |> render_change(%{"q" => "bernadette", "sort" => "recent"})
    assert has_element?(view, "#saved-people li", "Bernadette")
    refute has_element?(view, "#saved-people li", "Conrad")
  end

  test "removing a saved person from the People tab drops the row live", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    liked = other_user(first_name: "Removable")
    :ok = Vutuv.Social.like_user(user, liked)

    {:ok, view, _html} = live(conn, ~p"/likes?tab=people")
    assert has_element?(view, "#saved-people li", "Removable")

    view |> element("#saved-people li button[phx-click='unsave-person']") |> render_click()

    refute has_element?(view, "#saved-people li", "Removable")
    assert %{liked?: false} = Vutuv.Social.user_saved_flags(user, liked)
  end

  test "liking a member in another session prepends them live", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, view, _html} = live(conn, ~p"/likes?tab=people")

    target = other_user(first_name: "Lively")
    :ok = Vutuv.Social.like_user(user, target)
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#saved-people li", "Lively")
  end
end
