defmodule VutuvWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias VutuvWeb.Markdown

  defp render(text), do: text |> Markdown.render() |> Phoenix.HTML.safe_to_string()

  test "renders bold, italics and inline code" do
    html = render("**bold** and _italic_ and `code`")
    assert html =~ "<strong>bold</strong>"
    assert html =~ "<em>italic</em>"
    assert html =~ "<code"
  end

  test "renders markdown links opening in a new tab" do
    html = render("see [the docs](https://hexdocs.pm/phoenix)")
    assert html =~ ~s(href="https://hexdocs.pm/phoenix")
    assert html =~ ~s(target="_blank")
    assert html =~ ~s(rel="noopener noreferrer")
    assert html =~ ">the docs</a>"
  end

  test "autolinks bare URLs and truncates long display text" do
    url = "https://en.wikipedia.org/wiki/Elixir_(programming_language)?utm_source=very_long"
    html = render("look at #{url} now")

    assert html =~ ~s(href="#{url}")
    # display text is scheme-less and truncated with an ellipsis
    assert html =~ "en.wikipedia.org/wiki/Elixir_(programmi…"
    refute html =~ ">https://en.wikipedia.org"
  end

  test "newlines become line breaks" do
    assert render("line one\nline two") =~ "<br"
  end

  describe "render_preview/3 truncation" do
    defp preview(text, opts \\ []) do
      {html, truncated?} = Markdown.render_preview(text, [], opts)
      {Phoenix.HTML.safe_to_string(html), truncated?}
    end

    test "short content is rendered whole and not marked truncated" do
      {html, truncated?} = preview("Just a short post.")

      assert html =~ "Just a short post."
      refute truncated?
    end

    test "a one-line intro above a long block keeps part of that block (not just the intro)" do
      intro = "Testing this self-improvement rule for my setup:"
      long = "- " <> String.duplicate("word ", 400)

      {html, truncated?} = preview(intro <> "\n\n" <> long)

      assert truncated?
      assert html =~ "Testing this self-improvement rule"
      # The long block is word-cut into the preview instead of being dropped, so
      # its text and list markup appear — it used to collapse to just the intro.
      assert html =~ "<li>"
      assert html =~ "word word"
    end

    test "an overflowing fenced code block is kept whole rather than cut mid-fence" do
      intro = "Here is the code:"
      fence = "```\n" <> String.duplicate("x = 1\n", 300) <> "```"

      {html, truncated?} = preview(intro <> "\n\n" <> fence)

      assert truncated?
      assert html =~ "Here is the code"
      # Cutting a fence breaks rendering, so it is included whole (the CSS clamp
      # trims it visually) — the preview is never stranded on the intro line.
      assert html =~ "x = 1"
    end
  end

  test "raw HTML shows as literal text and never executes" do
    html = render(~s|<script>alert("x")</script> **safe**|)
    refute html =~ "<script"
    # the typed tag is displayed, escaped
    assert html =~ "&lt;script"
    assert html =~ "<strong>safe</strong>"
  end

  test "strips javascript: links" do
    html = render("[click](javascript:alert(1))")
    refute html =~ "javascript:"
  end

  test "non-binary input renders as empty" do
    assert Phoenix.HTML.safe_to_string(Markdown.render(nil)) == ""
  end
end
