defmodule VutuvWeb.CV.MarkdownBlocksTest do
  @moduledoc """
  The shared Markdown-to-plain-blocks floor of the CV document exports
  (issue #920): Word, OpenDocument and LaTeX cannot take the profile's HTML
  pipeline, so a description reduces to paragraphs (with line breaks),
  bullet / numbered lists, and inline markers stripped to their text.
  """
  use ExUnit.Case, async: true

  alias VutuvWeb.CV.MarkdownBlocks

  describe "blocks/1" do
    test "keeps paragraphs and line breaks" do
      assert MarkdownBlocks.blocks("One\ntwo\n\nThree") == [{:p, "One\ntwo"}, {:p, "Three"}]
    end

    test "strips inline markers to their text" do
      assert MarkdownBlocks.blocks("**Bold** and _italic_ and `code`") ==
               [{:p, "Bold and italic and code"}]
    end

    test "keeps a labelled link's URL beside its text" do
      assert MarkdownBlocks.blocks("See [the docs](https://example.org/docs)") ==
               [{:p, "See the docs (https://example.org/docs)"}]
    end

    test "a bare URL stays one URL, not doubled" do
      assert MarkdownBlocks.blocks("See https://example.org/docs") ==
               [{:p, "See https://example.org/docs"}]
    end

    test "bullet and numbered lists become item lists" do
      assert MarkdownBlocks.blocks("- **one**\n- two\n\n1. first\n2. second") ==
               [{:ul, ["one", "two"]}, {:ol, ["first", "second"]}]
    end

    test "headings and blockquotes flatten to paragraphs" do
      assert MarkdownBlocks.blocks("## Rollout\n\n> quoted line") ==
               [{:p, "Rollout"}, {:p, "quoted line"}]
    end

    test "raw HTML-ish text passes through as literal text" do
      assert MarkdownBlocks.blocks("Shipping <fast> & 100% maintainable code_bases") ==
               [{:p, "Shipping <fast> & 100% maintainable code_bases"}]
    end

    test "images are dropped, like everywhere else" do
      assert MarkdownBlocks.blocks("![a pic](https://example.org/pic.png)\n\ntext") ==
               [{:p, "text"}]
    end

    test "a fenced code block keeps its lines verbatim" do
      assert MarkdownBlocks.blocks("```\nmix test\nmix deploy\n```") ==
               [{:p, "mix test\nmix deploy"}]
    end
  end

  describe "plain/1" do
    test "reduces the whole description to one line for compact hints" do
      assert MarkdownBlocks.plain("**Led** the team\n\n- built\n- shipped") ==
               "Led the team built · shipped"
    end
  end
end
