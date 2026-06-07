defmodule VutuvWeb.MarkdownPostTest do
  @moduledoc """
  Post rendering on top of the chat pipeline: inline images may reference
  only the post's **own attachments** (hotlinked remote images are a tracking
  hole — every reader's IP would leak to a third party), missing alt text is
  filled from the stored value, and the preview truncation never cuts inside
  a fenced code block.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Posts.PostImage
  alias VutuvWeb.Markdown

  defp image(token, alt \\ "") do
    %PostImage{token: token, alt: alt, width: 800, height: 600}
  end

  defp render_post(text, images) do
    text |> Markdown.render_post(images) |> Phoenix.HTML.safe_to_string()
  end

  describe "render_post/2 — inline images" do
    test "renders an own-attachment reference as an <img> with stored alt" do
      html =
        render_post("Look:\n\n![](/post_images/tok123/large.avif)", [image("tok123", "A sunset")])

      assert html =~ ~s(src="/post_images/tok123/large.avif")
      assert html =~ ~s(alt="A sunset")
      assert html =~ ~s(loading="lazy")
      assert html =~ ~s(width="800")
    end

    test "a legacy .webp reference in an old body renders with the canonical src" do
      html =
        render_post("Look:\n\n![](/post_images/tok123/large.webp)", [image("tok123", "A sunset")])

      assert html =~ ~s(src="/post_images/tok123/large.avif")
      refute html =~ "large.webp"
    end

    test "an explicit markdown alt wins over the stored one" do
      html =
        render_post("![Inline alt](/post_images/tok123/feed.avif)", [image("tok123", "DB alt")])

      assert html =~ ~s(alt="Inline alt")
      refute html =~ "DB alt"
    end

    test "the same attachment can be referenced twice" do
      text = "![](/post_images/t/large.avif)\n\n![](/post_images/t/large.avif)"
      html = render_post(text, [image("t")])

      assert length(String.split(html, "<img")) == 3
    end

    test "drops hotlinked remote images entirely" do
      html = render_post("before ![tracker](https://evil.example/pixel.png) after", [])

      refute html =~ "<img"
      refute html =~ "evil.example"
      assert html =~ "before"
      assert html =~ "after"
    end

    test "drops references to images of other posts" do
      html = render_post("![](/post_images/foreign/large.avif)", [image("mine")])

      refute html =~ "<img"
    end

    test "never resolves the original through an inline reference" do
      html = render_post("![](/post_images/t/original.jpg)", [image("t")])

      refute html =~ "<img"
    end

    test "raw <img> HTML typed by the author stays escaped text" do
      html = render_post(~s(<img src="/post_images/t/large.avif">), [image("t")])

      refute html =~ "<img "
      assert html =~ "&lt;img"
    end

    test "escapes hostile stored alt text" do
      hostile = ~s["><script>alert(1)</script>"]
      html = render_post("![](/post_images/t/large.avif)", [image("t", hostile)])

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "the rest of the markdown still renders" do
      html = render_post("**bold** and ![](/post_images/t/feed.avif)", [image("t")])

      assert html =~ "<strong>bold</strong>"
      assert html =~ "<img"
    end
  end

  describe "render_preview/2" do
    test "short text passes through untruncated" do
      {html, truncated?} = Markdown.render_preview("just a line", [])

      refute truncated?
      assert Phoenix.HTML.safe_to_string(html) =~ "just a line"
    end

    test "cuts long text at a paragraph boundary" do
      para = "word " |> String.duplicate(60) |> String.trim()
      text = Enum.join(List.duplicate(para, 5), "\n\n")

      {html, truncated?} = Markdown.render_preview(text, [])

      assert truncated?
      out = Phoenix.HTML.safe_to_string(html)
      kept_paragraphs = length(String.split(out, "<p>")) - 1
      assert kept_paragraphs >= 1
      assert kept_paragraphs < 5
    end

    test "never cuts inside a fenced code block" do
      code = "```\n" <> String.duplicate("a line of code\n", 120) <> "```"

      {html, truncated?} = Markdown.render_preview(code <> "\n\nafter the fence", [])

      assert truncated?
      out = Phoenix.HTML.safe_to_string(html)
      assert out =~ "<code"
      # The fence stayed balanced: no literal backticks leak into the output.
      refute out =~ "```"
      refute out =~ "after the fence"
    end

    test "a single overlong paragraph is word-cut with an ellipsis" do
      text = "somelongword " |> String.duplicate(200) |> String.trim()

      {html, truncated?} = Markdown.render_preview(text, [])

      assert truncated?
      out = Phoenix.HTML.safe_to_string(html)
      assert out =~ "…"
      assert String.length(out) < 1200
      # The cut landed between words, not inside one.
      refute out =~ "somelongwor…"
    end

    test "blank lines inside a fence do not split it" do
      code = "```\nfirst\n\nsecond\n```"
      long_tail = "tail " |> String.duplicate(300) |> String.trim()

      {html, truncated?} = Markdown.render_preview(code <> "\n\n" <> long_tail, [])

      assert truncated?
      out = Phoenix.HTML.safe_to_string(html)
      assert out =~ "first"
      assert out =~ "second"
      refute out =~ "```"
    end
  end
end
