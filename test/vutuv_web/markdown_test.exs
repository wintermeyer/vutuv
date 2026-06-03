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
