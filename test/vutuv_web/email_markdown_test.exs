defmodule VutuvWeb.EmailMarkdownTest do
  use ExUnit.Case, async: true

  alias VutuvWeb.EmailMarkdown

  defp html(text), do: text |> EmailMarkdown.render() |> Phoenix.HTML.safe_to_string()

  describe "render/1" do
    test "turns a bare URL into a clickable link that keeps its full text" do
      url = "https://vutuv.de/oliverandrich/posts/019f480d-db7f-77a1-8841-fc517455f42f"
      out = html("See #{url} now.")

      # Full URL is both the href and the visible text (no host-only truncation
      # like the post/message renderer does).
      assert out =~ ~s(href="#{url}")
      assert out =~ ">#{url}</a>"
    end

    test "renders a Markdown link" do
      out = html("[the thread](https://example.com/foo)")
      assert out =~ ~s(href="https://example.com/foo")
      assert out =~ ">the thread</a>"
    end

    test "opens links in a new tab" do
      out = html("Visit https://example.com now")
      assert out =~ ~s(target="_blank")
      assert out =~ ~s(rel="noopener noreferrer")
    end

    test "keeps the full Markdown feature set that posts drop" do
      out = html("# Heading\n\ntext")
      # Headings stay headings (posts flatten them to bold).
      assert out =~ "<h1>"

      assert html("**bold** _italic_") =~ "<strong>bold</strong>"
      assert html("- a\n- b") =~ "<ul>"
      assert html("> quoted") =~ "<blockquote>"
    end

    test "escapes raw HTML the writer types, so it shows as literal text" do
      out = html("<b>x</b> and <script>alert(1)</script>")
      refute out =~ "<b>"
      refute out =~ "<script>"
      assert out =~ "&lt;b&gt;"
      assert out =~ "&lt;script&gt;"
    end

    test "drops a javascript: link target" do
      out = html("[x](javascript:alert(1))")
      refute out =~ "javascript:"
    end

    test "strips images (no tracking pixels in an invitation)" do
      out = html("![pixel](https://evil.example/p.png)")
      refute out =~ "<img"
    end

    test "returns empty safe HTML for non-binaries" do
      assert Phoenix.HTML.safe_to_string(EmailMarkdown.render(nil)) == ""
    end
  end
end
