defmodule VutuvWeb.MarkdownQuoteTest do
  @moduledoc """
  `VutuvWeb.Markdown.blockquote/1` — the Markdown source the reply composer
  opens with when the reader selected part of a post before pressing Reply
  (issue #1114). The excerpt comes from a browser text selection, so the tests
  cover the shapes a selection really has: stray indentation, blank lines, and
  a reader who marked half the page.
  """
  use ExUnit.Case, async: true

  alias VutuvWeb.Markdown

  test "wraps the selection in a blockquote and leaves a line for the answer" do
    assert Markdown.blockquote("the point I answer") == "> the point I answer\n\n"
  end

  test "quotes every line and keeps a paragraph break inside the quote" do
    assert Markdown.blockquote("first line\n\nsecond line") ==
             "> first line\n>\n> second line\n\n"
  end

  test "drops the indentation a DOM selection carries along" do
    assert Markdown.blockquote("  \n  indented  \n\t tabbed\n") == "> indented\n> tabbed\n\n"
  end

  test "an empty selection is nil, so a bare query parameter can be passed in" do
    assert Markdown.blockquote("") == nil
    assert Markdown.blockquote("   \n  ") == nil
    assert Markdown.blockquote(nil) == nil
  end

  test "caps a long selection at the last whole word" do
    quoted = Markdown.blockquote(String.duplicate("wort ", 200))

    assert String.starts_with?(quoted, "> wort wort")
    assert String.ends_with?(quoted, " …\n\n")
    # The cap plus the quote marker and the ellipsis, nothing near the 1000
    # characters that went in.
    assert String.length(quoted) < 520
  end

  test "cuts a word too long to cut back rather than dropping it" do
    quoted = Markdown.blockquote(String.duplicate("a", 700))

    assert String.starts_with?(quoted, "> " <> String.duplicate("a", 500))
    assert String.ends_with?(quoted, "…\n\n")
  end
end
