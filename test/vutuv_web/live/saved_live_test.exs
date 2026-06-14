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
end
