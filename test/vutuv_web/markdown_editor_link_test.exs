defmodule VutuvWeb.MarkdownEditorLinkTest do
  use ExUnit.Case, async: true

  # Paste a URL into the composer, let it become a link (a draft restore, a
  # post edit or any other server re-seed parses it with GFM autolink), put
  # the caret at its end and type: the space that is meant to END the link —
  # and every word after it — joined the link instead, so the stored Markdown
  # became `[https://example.com more words](https://example.com)`.
  #
  # Mechanism: ProseMirror marks are "inclusive" by default (typing at a
  # mark's right edge inherits it) and Milkdown's commonmark linkSchema does
  # not say otherwise. The fix extends the link schema with
  # `inclusive: false`; mark registration is last-wins, so the extension must
  # be `.use`d after the commonmark preset to replace its link mark.
  #
  # There is no JS test runner in this project, so this is a static source
  # check in the spirit of `markdown_editor_resize_test.exs`.

  @editor_js Path.expand("../../assets/js/markdown_editor.js", __DIR__)

  defp editor_js, do: File.read!(@editor_js)

  defp position_of(js, needle) do
    case :binary.match(js, needle) do
      {pos, _len} -> pos
      :nomatch -> flunk("expected markdown_editor.js to contain `#{needle}`")
    end
  end

  test "the link mark schema is extended to be non-inclusive" do
    assert editor_js() =~ ~r/linkSchema\.extendSchema\([\s\S]{0,200}?inclusive:\s*false/,
           "markdown_editor.js must extend Milkdown's linkSchema with " <>
             "`inclusive: false` — without it, typing at the end of a link " <>
             "(the space after a pasted URL) extends the link over everything " <>
             "typed after it"
  end

  test "the non-inclusive link schema is registered after the commonmark preset" do
    js = editor_js()

    assert position_of(js, ".use(nonInclusiveLink)") > position_of(js, ".use(commonmark)"),
           "the extended link schema must be `.use`d after `.use(commonmark)`: " <>
             "Milkdown registers marks last-wins, so used earlier it would be " <>
             "overwritten by the preset's inclusive default"
  end
end
