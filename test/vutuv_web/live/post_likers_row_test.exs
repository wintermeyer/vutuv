defmodule VutuvWeb.PostLikersRowTest do
  @moduledoc """
  The "Liked by" row on a post permalink (issue #1233): whose faces it shows,
  who is left out, what the post's author sees instead, and that none of it
  moves the like count.

  async: false — one test injects installation defaults into the node-global
  `Vutuv.Prefs.Cache` (`:persistent_term`), which every other test rendering a
  post would read.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias Vutuv.Prefs
  alias Vutuv.Prefs.Cache

  setup %{conn: conn} do
    {conn, author} = create_and_login_user(conn)
    post = create_post!(author, %{body: "Suspension bridges are underrated."})

    # The embedded thread resolves the viewer from the cookie's session_token
    # (issue #1036), never a bare user_id, so its tests hand it a real session.
    {:ok, author: author, post: post, owner: Plug.Conn.get_session(conn)}
  end

  defp thread_view(post, cookie \\ %{}, locale \\ "en") do
    session = Map.merge(cookie, %{"post_id" => post.id, "locale" => locale})

    live_isolated(build_conn(), VutuvWeb.PostLive.Thread, session: session)
  end

  defp like!(post, attrs) do
    fan = insert_activated_user(attrs)
    :ok = Posts.like_post(fan, post)
    fan
  end

  # How many faces the rendered row shows (each face carries `data-stack-face`).
  defp face_count(html), do: html |> String.split("data-stack-face") |> length() |> Kernel.-(1)

  describe "who the row names" do
    test "a liker who allows attribution appears, with their name in the sentence", %{post: post} do
      like!(post, first_name: "Fanny", last_name: "Fan")

      {:ok, _view, html} = thread_view(post)

      assert html =~ "data-post-likers"
      assert html =~ "Liked by Fanny Fan"
      assert face_count(html) == 1
    end

    test "a liker who opted out is not named — but the count still counts them", %{post: post} do
      like!(post, first_name: "Loud", last_name: "Liker")
      like!(post, first_name: "Shy", last_name: "Liker", like_attribution?: false)

      {:ok, _view, html} = thread_view(post)

      assert html =~ "Liked by Loud Liker"
      refute html =~ "Shy Liker"
      # One face, one hidden member: the row stands for both, so the tail chip
      # covers the one it cannot show. The number itself never shrinks.
      assert face_count(html) == 1
      assert html =~ "and 1 other"
      assert Posts.engagement_counts(post.id).likes == 2
    end

    test "renders no row at all while nobody may be named", %{post: post} do
      like!(post, like_attribution?: false)

      {:ok, _view, html} = thread_view(post)

      refute html =~ "data-post-likers"
      refute html =~ "Liked by"
    end

    test "renders no row on a post nobody liked", %{post: post} do
      {:ok, _view, html} = thread_view(post)

      refute html =~ "data-post-likers"
    end

    test "an installation that turns attribution off names nobody by default", %{post: post} do
      Cache.store(Map.merge(Prefs.shipped_defaults(), %{like_attribution?: false}))
      on_exit(&Cache.clear/0)

      like!(post, first_name: "Untouched", last_name: "Setting")

      {:ok, _view, html} = thread_view(post)

      refute html =~ "Untouched Setting"
      refute html =~ "data-post-likers"
    end
  end

  describe "a page's like (issue #1410)" do
    test "a page gets a face: its name in the sentence, its logo linking to its page", %{
      post: post
    } do
      page = insert(:organization, name: "Formkurve GmbH")
      page_like!(post, page)

      {:ok, _view, html} = thread_view(post)

      assert html =~ "data-post-likers"
      assert html =~ "Liked by Formkurve GmbH"
      assert face_count(html) == 1
      assert html =~ ~s(href="/organizations/#{page.slug}")
    end

    test "a page and a member share the row like two members would", %{post: post} do
      like!(post, first_name: "Fanny", last_name: "Fan")
      page = insert(:organization, name: "Formkurve GmbH")
      page_like!(post, page)

      {:ok, _view, html} = thread_view(post)

      # The page liked last, so the sentence names it; the member keeps a face.
      assert html =~ "Liked by Formkurve GmbH and 1 other"
      assert face_count(html) == 2
    end
  end

  describe "the post's author" do
    test "sees the liker who opted out, and is told the row is theirs alone", %{
      post: post,
      owner: owner
    } do
      like!(post, first_name: "Shy", last_name: "Liker", like_attribution?: false)

      {:ok, _view, html} = thread_view(post, owner)

      # They were named in the like notification at the time, so the author
      # keeps seeing them — with the line that says nobody else does.
      assert html =~ "Liked by Shy Liker"
      assert html =~ "Only you see everyone here"
    end

    test "gets no such line when every liker is public anyway", %{post: post, owner: owner} do
      like!(post, first_name: "Loud", last_name: "Liker")

      {:ok, _view, html} = thread_view(post, owner)

      assert html =~ "Liked by Loud Liker"
      refute html =~ "Only you see everyone here"
    end
  end

  describe "the row's place" do
    test "rides the permalinked post only, never the replies around it", %{post: post} do
      {:ok, reply} =
        Posts.create_reply(insert_activated_user(), post, %{"body" => "Agreed, very sturdy."})

      like!(reply, first_name: "Reply", last_name: "Liker")

      {:ok, _view, html} = thread_view(post)

      # The reply's own like has a face on the reply's page, not on this one.
      refute html =~ "Reply Liker"
      refute html =~ "data-post-likers"

      {:ok, _view, reply_html} = thread_view(reply)
      assert reply_html =~ "Liked by Reply Liker"
    end

    test "a like landing while the page is open moves the faces with the counter", %{post: post} do
      {:ok, view, html} = thread_view(post)
      refute html =~ "data-post-likers"

      fan = insert_activated_user(first_name: "Late", last_name: "Arrival")
      :ok = Posts.like_post(fan, post)

      html = render(view)
      assert html =~ "Liked by Late Arrival"
    end
  end

  describe "German" do
    test "names the liker in German", %{post: post} do
      like!(post, first_name: "Frida", last_name: "Freundlich")

      {:ok, _view, html} =
        thread_view(post, %{}, "de")

      assert html =~ "Gefällt Frida Freundlich"
    end

    test "counts the members it cannot name, in German", %{post: post} do
      like!(post, first_name: "Frida", last_name: "Freundlich")
      like!(post, like_attribution?: false)
      like!(post, like_attribution?: false)

      {:ok, _view, html} = thread_view(post, %{}, "de")

      assert html =~ "Gefällt Frida Freundlich und 2 weiteren"
    end
  end
end
