defmodule VutuvWeb.PostScreenshotRenderTest do
  @moduledoc """
  A ready link screenshot floats beside its post's text; a not-yet-captured one
  renders nothing. Exercised through the post permalink (`:full` mode) and the
  profile page (`:preview` mode).
  """
  use VutuvWeb.ConnCase

  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Repo

  @body_text "Please go through the open issues at"

  defp author, do: insert(:activated_user)

  defp post_with_screenshot(author, attrs) do
    post = create_post!(author, %{body: "#{@body_text} https://example.com/page"})

    Repo.insert!(
      struct(
        %PostScreenshot{post_id: post.id, url: "https://example.com/page", status: "pending"},
        attrs
      )
    )

    post
  end

  describe "post permalink (full mode)" do
    test "shows the screenshot once it is ready", %{conn: conn} do
      user = author()
      post = post_with_screenshot(user, status: "ready", screenshot: "abcdef012345.avif")

      html = html_response(get(conn, Posts.path(post)), 200)
      assert html =~ "data-link-screenshot"
    end

    test "floats it beside the text rather than stacking it below", %{conn: conn} do
      user = author()
      post = post_with_screenshot(user, status: "ready", screenshot: "abcdef012345.avif")

      html = html_response(get(conn, Posts.path(post)), 200)

      # The float lives on the screenshot element itself ...
      assert [tag] = Regex.run(~r/<div[^>]*data-link-screenshot[^>]*>/, html)
      assert tag =~ "float-right"

      # ... and inside the body container, ahead of the prose: a CSS float only
      # wraps the content that FOLLOWS it, so a screenshot rendered as a block
      # after the body lands below the text instead of beside it. Split at the
      # body container first — the post body also rides along in the page's
      # <head> metadata, which would otherwise win the position comparison.
      assert [_head, body_flow] = String.split(html, "markdown--post", parts: 2)
      assert at(body_flow, "data-link-screenshot") < at(body_flow, @body_text)
    end

    test "shows nothing while the screenshot is still pending", %{conn: conn} do
      user = author()
      post = post_with_screenshot(user, status: "pending")

      html = html_response(get(conn, Posts.path(post)), 200)
      refute html =~ "data-link-screenshot"
    end
  end

  describe "the magnifier" do
    test "a ready capture offers one trigger, on the thumb, outside the link",
         %{conn: conn} do
      user = author()
      post = post_with_screenshot(user, status: "ready", screenshot: "abcdef012345.avif")

      html = html_response(get(conn, Posts.path(post)), 200)

      assert html =~ "data-lightbox-gallery"
      assert [_] = elements(html, "[data-lightbox-photo]")

      # The server names the file, so the overlay never has to read it back off
      # the page — which file it names is `screenshot_lightbox_url_test.exs`.
      assert html =~ "data-photo-src"

      # The anchor is a decorative duplicate of the body's link and is hidden
      # from assistive tech; a focusable control inside it would be a tab stop
      # no screen reader can announce.
      assert [] = elements(html, "a[aria-hidden] [data-lightbox-photo]")
    end
  end

  # Source-order position of `needle`, so a test can pin that one piece of
  # markup comes before another.
  defp at(html, needle) do
    assert {start, _length} = :binary.match(html, needle)
    start
  end

  describe "profile page (preview mode)" do
    test "floats the screenshot beside the post so the text wraps around it", %{conn: conn} do
      user = author()
      _post = post_with_screenshot(user, status: "ready", screenshot: "abcdef012345.avif")

      html = html_response(get(conn, ~p"/#{user.username}"), 200)
      assert html =~ "data-link-screenshot"
      # The float-wrap layout: the screenshot floats and the body clamps by height
      # so the text flows around AND below it (no dead column beside a short shot).
      assert html =~ "float-right"
      assert html =~ "post-clamp--wrap"
    end
  end
end
