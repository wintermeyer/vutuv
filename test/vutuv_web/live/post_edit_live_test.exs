defmodule VutuvWeb.PostEditLiveTest do
  @moduledoc """
  The edit page: author-only, prefilled composer, saving redirects to the
  permalink with the audience replaced, and the permalink coordinates never
  change.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Posts

  describe "GET /posts/:id/edit" do
    test "prefills the composer for the author", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, post} =
        Posts.create_post(user, %{
          body: "draft words",
          tags: "elixir",
          denials: [%{"wildcard" => "non_followers"}]
        })

      {:ok, live, html} = live(conn, ~p"/posts/#{post.id}/edit")

      assert html =~ "draft words"
      assert html =~ "elixir"

      assert live |> element("#composer-preset") |> render() =~
               ~s(option value="followers" selected)
    end

    test "saving updates the post and navigates to the permalink", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "before"})

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")

      live
      |> form("#composer-form", %{"post" => %{"body" => "after", "preset" => "only_me"}})
      |> render_submit()

      assert_redirect(live, Posts.path(post))

      updated = Posts.get_post(post.id)
      assert updated.body == "after"
      assert [%{wildcard: "everyone"}] = updated.denials
      assert updated.published_on == post.published_on
    end

    test "locks the audience while reposts exist", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "carried by others"})
      :ok = Posts.repost_post(insert(:user, email_confirmed?: true), post)

      {:ok, live, html} = live(conn, ~p"/posts/#{post.id}/edit")

      # No audience select; the locked chip and the explanation instead.
      refute has_element?(live, "#composer-preset")
      assert has_element?(live, "#composer-audience-locked")
      assert html =~ "reposted"

      # Body edits still save (and the post stays public).
      live
      |> form("#composer-form", %{"post" => %{"body" => "still editable"}})
      |> render_submit()

      assert_redirect(live, Posts.path(post))
      assert Posts.get_post(post.id).body == "still editable"
      assert Posts.get_post(post.id).denials == []
    end

    test "locks the audience while replies exist", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "carried by a thread"})

      {:ok, _} =
        Posts.create_reply(insert(:user, email_confirmed?: true), post, %{body: "the answer"})

      {:ok, live, html} = live(conn, ~p"/posts/#{post.id}/edit")

      refute has_element?(live, "#composer-preset")
      assert has_element?(live, "#composer-audience-locked")
      assert html =~ "replies"
    end

    test "sends non-authors away without confirming existence", %{conn: conn} do
      author = insert(:user, email_confirmed?: true)
      {:ok, post} = Posts.create_post(author, %{body: "not yours"})

      {conn, _other} = create_and_login_user(conn)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/posts/#{post.id}/edit")
      # A valid-but-absent id and a garbage id both redirect (no 500, no probe).
      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, ~p"/posts/#{Vutuv.UUIDv7.generate()}/edit")

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/posts/999999/edit")
    end
  end
end
