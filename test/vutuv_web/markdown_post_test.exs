defmodule VutuvWeb.MarkdownPostTest do
  @moduledoc """
  Post rendering on top of the chat pipeline: post **bodies never embed
  images** — every `<img>` the pipeline would produce (an own-attachment
  `![](…)` reference, a hotlinked remote picture, raw `<img>` HTML) is
  dropped or stays escaped text. Uploaded pictures show as a separate gallery
  (`VutuvWeb.PostComponents`), not inline in the prose. The preview
  truncation never cuts inside a fenced code block.
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

  describe "render_post/2 — images are never embedded in the body" do
    test "an own-attachment reference is dropped, not rendered as an <img>" do
      html =
        render_post("Look:\n\n![](/post_images/tok123/large.avif)", [image("tok123", "A sunset")])

      refute html =~ "<img"
      refute html =~ "large.avif"
      assert html =~ "Look"
    end

    test "a legacy .webp reference in an old body is dropped too" do
      html =
        render_post("Look:\n\n![](/post_images/tok123/large.webp)", [image("tok123", "A sunset")])

      refute html =~ "<img"
      refute html =~ "large.webp"
    end

    test "the stored alt text never reaches the output" do
      html = render_post("![](/post_images/tok123/feed.avif)", [image("tok123", "A sunset")])

      refute html =~ "<img"
      refute html =~ "A sunset"
    end

    test "drops hotlinked remote images entirely" do
      html = render_post("before ![tracker](https://evil.example/pixel.png) after", [])

      refute html =~ "<img"
      refute html =~ "evil.example"
      assert html =~ "before"
      assert html =~ "after"
    end

    test "raw <img> HTML typed by the author stays escaped text" do
      html = render_post(~s(<img src="/post_images/t/large.avif">), [image("t")])

      refute html =~ "<img "
      assert html =~ "&lt;img"
    end

    test "a hostile stored alt cannot inject markup" do
      hostile = ~s["><script>alert(1)</script>"]
      html = render_post("![](/post_images/t/large.avif)", [image("t", hostile)])

      refute html =~ "<script>"
      refute html =~ "<img"
    end

    test "the rest of the markdown still renders around a dropped image" do
      html = render_post("**bold** and ![](/post_images/t/feed.avif)", [image("t")])

      assert html =~ "<strong>bold</strong>"
      refute html =~ "<img"
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
