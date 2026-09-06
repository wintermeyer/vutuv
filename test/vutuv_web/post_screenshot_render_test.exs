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

  defp post_with_screenshot(author, attrs, post_attrs \\ %{}) do
    post =
      create_post!(
        author,
        Map.merge(%{body: "#{@body_text} https://example.com/page"}, post_attrs)
      )

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

    test "from `lg` up it floats beside the text, as the body's first child", %{conn: conn} do
      user = author()
      post = post_with_screenshot(user, status: "ready", screenshot: "abcdef012345.avif")

      html = html_response(get(conn, Posts.path(post)), 200)

      # The float lives on the screenshot element itself, and only from the
      # `lg` breakpoint up: below it the same element is display:none, because
      # a third of a narrow column is a thumbnail nobody can read.
      assert [beside] = elements(html, "[data-link-screenshot=beside]")
      assert attribute(beside, "class") =~ "lg:float-right"
      assert attribute(beside, "class") =~ ~r/(^|\s)hidden(\s|$)/

      # ... and inside the body container, ahead of the prose: a CSS float only
      # wraps the content that FOLLOWS it, so a screenshot rendered as a block
      # after the body lands below the text instead of beside it. Split at the
      # body container first — the post body also rides along in the page's
      # <head> metadata, which would otherwise win the position comparison.
      assert [_head, body_flow] = String.split(html, "markdown--post", parts: 2)
      assert at(body_flow, ~s(data-link-screenshot="beside")) < at(body_flow, @body_text)
    end

    test "on a phone it stands full-width under the tags, ahead of the action bar",
         %{conn: conn} do
      user = author()

      post =
        post_with_screenshot(user, [status: "ready", screenshot: "abcdef012345.avif"], %{
          tags: "Tourism"
        })

      html = html_response(get(conn, Posts.path(post)), 200)

      # The phone's copy is a second element, since no CSS can move a float out
      # of the clamp block it has to sit in; it hides from `lg` up and never
      # floats.
      assert [below] = elements(html, "[data-link-screenshot=below]")
      assert attribute(below, "class") =~ "lg:hidden"
      refute attribute(below, "class") =~ "float"

      # Where a photo would stand: after the text and its tag row, before the
      # like/repost bar — the order a photo post already reads in.
      assert [_head, body_flow] = String.split(html, "markdown--post", parts: 2)
      tag_row = at(body_flow, "data-post-tags")
      shot = at(body_flow, ~s(data-link-screenshot="below"))
      assert tag_row < shot
      assert shot < at(body_flow, "post-actions-")
    end

    test "shows nothing while the screenshot is still pending", %{conn: conn} do
      user = author()
      post = post_with_screenshot(user, status: "pending")

      html = html_response(get(conn, Posts.path(post)), 200)
      refute html =~ "data-link-screenshot"
    end
  end

  describe "the magnifier" do
    test "each placement offers one trigger, on its thumb, outside the link",
         %{conn: conn} do
      user = author()
      post = post_with_screenshot(user, status: "ready", screenshot: "abcdef012345.avif")

      html = html_response(get(conn, Posts.path(post)), 200)

      # One gallery per placement, each holding its one trigger: the two copies
      # show the same capture, so a gallery spanning both would offer the
      # overlay a "next photo" that is this photo again.
      assert [_, _] = elements(html, "[data-lightbox-gallery][data-link-screenshot]")
      assert [_] = elements(html, "[data-link-screenshot=beside] [data-lightbox-photo]")
      assert [_] = elements(html, "[data-link-screenshot=below] [data-lightbox-photo]")

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
      # The float-wrap layout: the screenshot floats and the body clamps by height
      # so the text flows around AND below it (no dead column beside a short shot).
      assert [beside] = elements(html, "[data-link-screenshot=beside]")
      assert attribute(beside, "class") =~ "lg:float-right"
      assert html =~ "post-clamp--wrap"
    end

    test "on a phone the shot leaves the clamp and stands under the tags", %{conn: conn} do
      user = author()

      _post =
        post_with_screenshot(user, [status: "ready", screenshot: "abcdef012345.avif"], %{
          tags: "Tourism"
        })

      html = html_response(get(conn, ~p"/#{user.username}"), 200)

      assert [below] = elements(html, "[data-link-screenshot=below]")
      assert attribute(below, "class") =~ "lg:hidden"

      # Outside the clamp block: inside it, a long body's cut would take the
      # picture away with the text. So it follows the whole preview — the
      # "Read more" control and the fallback tag row included — and precedes
      # the action bar.
      assert [_head, card] = String.split(html, "post-clamp--wrap", parts: 2)
      shot = at(card, ~s(data-link-screenshot="below"))
      assert at(card, "post-preview__tags-below") < shot
      assert at(card, "data-read-more") < shot
      assert shot < at(card, "post-actions-")
    end
  end
end
