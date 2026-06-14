defmodule VutuvWeb.PostReplyLiveTest do
  @moduledoc """
  The reply page (`/posts/:id/reply`): the parent post above the composer.
  Only visible, public parents can be answered; submitting creates a normal
  post plus its reply reference and returns to the parent's permalink.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Posts

  defp other_user(attrs \\ []), do: insert(:user, Keyword.merge([email_confirmed?: true], attrs))

  describe "GET /posts/:id/reply" do
    test "shows the parent post and the composer", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      parent =
        create_post!(other_user(first_name: "Petra", last_name: "Parent"), %{
          body: "the original"
        })

      {:ok, _live, html} = live(conn, ~p"/posts/#{parent.id}/reply")

      assert html =~ "the original"
      assert html =~ "Petra Parent"
      assert html =~ "composer-form"
    end

    test "redirects logged-out visitors to login", %{conn: conn} do
      parent = create_post!(other_user(), %{body: "x"})

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/posts/#{parent.id}/reply")
    end

    test "sends viewers away for restricted or invisible parents", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      restricted =
        create_post!(other_user(), %{body: "x", denials: [%{"wildcard" => "logged_out"}]})

      hidden =
        create_post!(other_user(), %{body: "x", denials: [%{"denied_user_id" => user.id}]})

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/posts/#{restricted.id}/reply")
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/posts/#{hidden.id}/reply")
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/posts/0/reply")
    end

    test "a blocked replier sees a reply-specific error, not the images message", %{conn: conn} do
      # Quiet blocking keeps the author's public post visible to the blocked
      # user, so the reply page mounts; the block only refuses on submit. The
      # error shown must be about replying, not the composer's image-count
      # catch-all.
      {conn, replier} = create_and_login_user(conn)
      author = other_user()
      {:ok, _} = Vutuv.Social.block_user(author, replier)
      parent = create_post!(author, %{body: "open to all"})

      {:ok, live, _html} = live(conn, ~p"/posts/#{parent.id}/reply")

      live
      |> form("#composer-form", %{"post" => %{"body" => "let me in", "preset" => "public"}})
      |> render_submit()

      assert live |> element("#composer-error") |> render() =~ "can no longer reply"
      assert Posts.list_replies(parent, author) == []
    end

    test "submitting creates the reply and returns to the parent", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      parent = create_post!(other_user(), %{body: "the question"})

      {:ok, live, _html} = live(conn, ~p"/posts/#{parent.id}/reply")

      live
      |> form("#composer-form", %{"post" => %{"body" => "the answer", "preset" => "public"}})
      |> render_submit()

      assert_redirect(live, Posts.path(parent))

      assert [reply] = Posts.list_replies(parent, user)
      assert reply.body == "the answer"
      assert reply.user_id == user.id
      assert reply.reply_ref.parent_post_id == parent.id
    end
  end
end
