defmodule VutuvWeb.MarkdownEditorResizeTest do
  use ExUnit.Case, async: true

  # Issue #1143: dragging the composer textarea taller and then pasting sprang
  # it back to its default height. `resize: vertical` makes the browser write
  # the drag onto the element's own inline `style`, and that textarea is the
  # server-rendered form field — so the next LiveView patch (every keystroke,
  # every paste) removes every attribute the server did not render, the inline
  # height with it. The `MarkdownEditor` hook already carries its view state
  # across that patch by hand; the height has to travel the same way.
  #
  # There is no JS test runner in this project, so this is a static source
  # check in the spirit of `dark_mode_css_test.exs` / `post_hyphenation_css_test.exs`:
  # it pins the CSS that hands the member the drag grip and the two halves of
  # the hook that keep what they dragged.

  @editor_js Path.expand("../../assets/js/markdown_editor.js", __DIR__)
  @components_css Path.expand("../../assets/css/components.css", __DIR__)

  defp editor_js, do: File.read!(@editor_js)
  defp components_css, do: File.read!(@components_css)

  test "the source textarea is resizable, which is what puts a height on its inline style" do
    assert components_css() =~ ~r/\.mde__source\s*\{[^}]*resize:\s*vertical/s,
           "`.mde__source` must keep `resize: vertical` — it is the grip the " <>
             "member drags, and the reason the hook has to preserve a height at all"
  end

  test "the hook remembers the dragged height before the patch drops it" do
    assert editor_js() =~ ~r/beforeUpdate\(\)\s*\{[^}]*this\.source\.style\.height/s,
           "the MarkdownEditor hook needs a beforeUpdate() that reads " <>
             "`this.source.style.height` — after the patch it is gone, so it " <>
             "can only be captured before"

    assert editor_js() =~ ~r/beforeUpdate\(\)\s*\{.*?this\.sourceHeight\s*=/s,
           "beforeUpdate() must store the height in `this.sourceHeight`"
  end

  test "applyState re-stamps the remembered height onto the textarea" do
    assert editor_js() =~
             ~r/applyState\(\)\s*\{.*?this\.source\.style\.height\s*=\s*this\.sourceHeight/s,
           "applyState() (called from updated(), inside the same synchronous " <>
             "patch, so nothing flickers) must write `this.sourceHeight` back " <>
             "onto the textarea"
  end
end
