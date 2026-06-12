defmodule VutuvWeb.OpenGraphTest do
  @moduledoc """
  The link-preview head tags (Open Graph + twitter:card) that WhatsApp,
  Facebook, LinkedIn, Signal and X render when a vutuv URL is shared.
  `VutuvWeb.OpenGraph` derives one set per page from the conn assigns and
  the root layout renders it on every HTML page; these tests prove the
  wiring per page family. The brand fallback image is `VutuvWeb.OgCard`.
  """
  use VutuvWeb.ConnCase

  import Vutuv.PostsHelpers

  alias Vutuv.Posts

  @base "http://localhost:4001"

  defp og(html, property) do
    case Regex.run(~r/<meta property="#{Regex.escape(property)}" content="([^"]*)"/, html) do
      [_, content] -> content
      nil -> nil
    end
  end

  describe "generic pages" do
    test "the landing page carries a full preview card", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert og(html, "og:site_name") == "vutuv"
      assert og(html, "og:type") == "website"
      assert og(html, "og:title") == "vutuv"
      assert og(html, "og:description") =~ "Career Network"
      assert og(html, "og:url") == @base <> "/"
      assert og(html, "og:image") == @base <> "/og-card.png"
      assert og(html, "og:image:width") == "1200"
      assert og(html, "og:image:height") == "630"
      assert html =~ ~s(<meta name="twitter:card" content="summary_large_image")
    end

    test "the plain description meta and og:description agree", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)

      [_, description] = Regex.run(~r/<meta name="description" content="([^"]*)"/, html)
      assert og(html, "og:description") == description
    end
  end

  describe "profile pages" do
    test "a member previews with name, work info and avatar", %{conn: conn} do
      user =
        insert_activated_user(
          first_name: "Greta",
          last_name: "Tester",
          avatar: "selfie.jpg"
        )

      insert(:work_experience, user: user, title: "Developer", organization: "Acme Corp")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert og(html, "og:type") == "profile"
      assert og(html, "og:title") == "Greta Tester"
      assert og(html, "og:description") =~ "Acme Corp"
      assert og(html, "og:url") == @base <> "/#{user.active_slug}"
      assert og(html, "og:image") == @base <> "/#{user.active_slug}/avatar.jpg"
      assert og(html, "og:image:width") == "512"
      assert og(html, "og:image:type") == "image/jpeg"
      assert html =~ ~s(<meta name="twitter:card" content="summary")
    end

    test "a member without an avatar falls back to the brand card", %{conn: conn} do
      user = insert_activated_user(first_name: "Bare")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert og(html, "og:image") == @base <> "/og-card.png"
    end

    test "a member without work info or tags gets the site description, never an empty one",
         %{conn: conn} do
      user = insert_activated_user(first_name: "Plain")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      description = og(html, "og:description")
      assert description != ""
      assert description =~ "Career Network"
    end
  end

  describe "post pages" do
    test "a public post previews as an article with its first line", %{conn: conn} do
      author = insert_activated_user(first_name: "Paula", avatar: "selfie.jpg")
      post = create_post!(author, %{"body" => "Hello preview world, this is the first line."})

      html = conn |> get(Posts.path(post)) |> html_response(200)

      assert og(html, "og:type") == "article"
      assert og(html, "og:description") =~ "Hello preview world"
      assert og(html, "article:published_time") == Date.to_iso8601(post.published_on)
      # The author's avatar gives the preview a face.
      assert og(html, "og:image") == @base <> "/#{author.active_slug}/avatar.jpg"
    end

    test "a post with images previews its first image instead of the avatar", %{conn: conn} do
      author = insert_activated_user(first_name: "Painter", avatar: "selfie.jpg")
      post = create_post!(author, %{"body" => "look at this"})

      # Position decides "first", not insertion order.
      insert(:post_image, post: post, user: author, position: 1, width: 800, height: 600)

      first =
        insert(:post_image,
          post: post,
          user: author,
          position: 0,
          width: 2000,
          height: 1000,
          alt: "A wide painting"
        )

      html = conn |> get(Posts.path(post)) |> html_response(200)

      assert og(html, "og:image") == @base <> "/post_images/#{first.token}/og.jpg"
      assert og(html, "og:image:width") == "1200"
      assert og(html, "og:image:height") == "600"
      assert og(html, "og:image:type") == "image/jpeg"
      assert og(html, "og:image:alt") == "A wide painting"
      assert html =~ ~s(<meta name="twitter:card" content="summary_large_image")
    end

    test "a restricted post's image stays out of the preview", %{conn: conn} do
      author = insert_activated_user(avatar: "selfie.jpg")

      post =
        create_post!(author, %{
          "body" => "members only",
          "denials" => [%{"wildcard" => "logged_out"}]
        })

      insert(:post_image, post: post, user: author, width: 800, height: 600)

      {member_conn, _member} = create_and_login_user(conn)
      html = member_conn |> get(Posts.path(post)) |> html_response(200)

      refute og(html, "og:image") =~ "/post_images/"
    end

    test "a restricted post never leaks its body into the preview", %{conn: conn} do
      author = insert_activated_user()

      post =
        create_post!(author, %{
          "body" => "secret words for members",
          "denials" => [%{"wildcard" => "logged_out"}]
        })

      # The permitted (logged-in) rendering still must not advertise the body:
      # scrapers fetch anonymously, but the tags shouldn't carry it anywhere.
      {member_conn, _member} = create_and_login_user(conn)
      html = member_conn |> get(Posts.path(post)) |> html_response(200)

      refute html =~ ~s(content="secret words)
      refute og(html, "og:description") =~ "secret words"
    end

    test "the teaser previews the author, not the post", %{conn: conn} do
      author = insert_activated_user(first_name: "Quiet")

      post =
        create_post!(author, %{
          "body" => "followers only content",
          "denials" => [%{"wildcard" => "non_followers"}]
        })

      html = conn |> get(Posts.path(post)) |> html_response(200)

      refute html =~ ~s(content="followers only)
      assert og(html, "og:type") == "profile"
    end
  end

  describe "GET /og-card.png" do
    test "serves the generated brand card, cacheable", %{conn: conn} do
      conn = get(conn, "/og-card.png")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
      assert [cache] = get_resp_header(conn, "cache-control")
      assert cache =~ "public"
      assert <<137, ?P, ?N, ?G, _rest::binary>> = conn.resp_body
    end
  end
end
