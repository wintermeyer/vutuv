defmodule VutuvWeb.SuggestListTest do
  @moduledoc """
  The editor opens two suggestion lists — the accounts offered after an `@`
  (`assets/js/mention_picker.js`) and the blocks offered after a `/` (the slash
  menu in `assets/js/markdown_editor.js`). Issue #1891 made them share their
  behaviour (`assets/js/suggest_list.js`) after the second one shipped with
  three defects the first had already fixed, and without the
  `aria-activedescendant` that is the whole of how a screen reader follows a
  listbox its user is not focused on.

  These are drift guards, not behaviour tests: the behaviour is client-side and
  `mix test` cannot run it. What they can pin is that the shared module stays
  the only definition — a second private copy of the wrap arithmetic, the
  active-row marking or the key table is exactly how the two grew apart the
  first time, and it is invisible until somebody fixes a bug in one of them.
  """
  use ExUnit.Case, async: true

  defp shared, do: File.read!("assets/js/suggest_list.js")
  defp picker, do: File.read!("assets/js/mention_picker.js")
  defp editor, do: File.read!("assets/js/markdown_editor.js")

  test "both lists import the shared behaviour" do
    assert picker() =~ ~s(from "./suggest_list")
    assert editor() =~ ~s(from "./suggest_list")
  end

  test "the wrap arithmetic is defined once" do
    # `(i + delta + count) % count` is the shape both lists had their own copy
    # of. It belongs to `stepIndex` now; a second one anywhere means the two
    # can disagree at the ends of a list again.
    assert shared() =~ "stepIndex"

    for {name, source} <- [{"mention_picker.js", picker()}, {"markdown_editor.js", editor()}] do
      refute source =~ ~r/\+\s*count\)\s*%\s*count/,
             "#{name} has its own wrap arithmetic; call stepIndex/3 instead"
    end
  end

  test "aria-activedescendant is written in one place" do
    # Both lists leave the caret in the prose, so this attribute is the only
    # thing that tells a screen-reader user which row Enter would take. The
    # slash menu shipped without it precisely because it was a second copy of
    # code that was never shared.
    assert shared() =~ "aria-activedescendant"

    for {name, source} <- [{"mention_picker.js", picker()}, {"markdown_editor.js", editor()}] do
      refute source =~ ~s(setAttribute("aria-activedescendant"),
             "#{name} sets aria-activedescendant itself; call markActiveRow/3 instead"
    end
  end

  test "one class means \"this row is highlighted\"" do
    # `.is-current` against `.is-active` was the drift: two lists in one editor
    # describing the same state with different words, so the stylesheet
    # described it twice and only one of them was ever updated.
    assert shared() =~ ~s(ACTIVE_CLASS = "is-active")

    css = File.read!("assets/css/components.css")
    # A SELECTOR, not the bare word: the rule above the mention rows explains
    # the rename in prose, and a refute on the word alone fails on its own
    # explanation.
    refute css =~ ~r/\.[\w-]+\.is-current/,
           "the stylesheet still styles an .is-current row somewhere"

    assert css =~ ".mention-picker__row.is-active"
    assert css =~ ".mde__slash-item.is-active"
  end

  test "\"follow the caret when the page moves\" is written once (issue #1898)" do
    # A panel pinned to a caret is wrong the moment the page moves under it,
    # and the editor only re-asks on a ProseMirror transaction — scrolling
    # dispatches none. The slash menu shipped without this and was placed once
    # on the way open, then abandoned; the bubble had an ad-hoc copy.
    assert shared() =~ "followsCaret"
    assert picker() =~ "followsCaret("
    assert editor() =~ "followsCaret("

    # `capture: true` on window is the whole trick — a scroll on an element
    # does not bubble but does travel down the capture phase, so one listener
    # sees the prose box scrolling as well as the page. A second copy of that
    # subtlety is how the two drifted apart in the first place.
    for {name, source} <- [{"mention_picker.js", picker()}, {"markdown_editor.js", editor()}] do
      refute source =~ ~r/addEventListener\(\s*"scroll"/,
             "#{name} wires its own scroll listener; call followsCaret/1 instead"
    end
  end

  test "the editor detaches its window listeners when it dies" do
    # `followsCaret` puts two handlers on `window`, which outlives every editor
    # on the page — and the messages page tears one down per closed
    # conversation, so an editor that never detaches leaks a handler per chat.
    source = editor()

    assert source =~ "this._unfollow = followsCaret("
    assert source =~ "if (this._unfollow) this._unfollow()"
  end

  test "a modified key is never a list key (issue #1196 vs #1886)" do
    # Cmd/Ctrl+Enter submits the composer from a listener on the same element.
    # A list that swallowed it turned a post into a heading — which is what the
    # slash menu did before this guard moved into the shared key table.
    assert shared() =~ "metaKey"
    assert shared() =~ "ctrlKey"
  end

  test "the editor keeps ONE keydown listener for its pop-up surfaces" do
    # Two capture-phase listeners on the same element cannot be ordered by
    # anything a reader can see: `stopPropagation` does not stop a sibling on
    # the same node, so priority came down to the order of two lines in
    # `mounted()`. There is one dispatcher now, and the order is written in it.
    source = editor()

    assert source =~ "wireSuggestKeys()"
    # The DEFINITION, not any mention of the name: a comment may still point at
    # the old one while explaining the change.
    refute source =~ ~r/^\s{2}wireMentionKeys\(\)\s*\{/m,
           "the second keydown listener is back"

    # Counting every keydown listener would be the wrong measure — the two
    # submit shortcuts and the full-screen Escape are all legitimate, and two
    # of those share `mountEl` quite safely because they are in different
    # phases. What must stay single is the DISPATCH: each surface's key handler
    # called from exactly one place, so the order between them is written down
    # rather than emerging from registration order.
    for handler <- ~w(handleSlashKey handleMentionKey) do
      calls = source |> String.split("this.#{handler}(event)") |> length() |> Kernel.-(1)

      assert calls == 1,
             "#{handler} is dispatched from #{calls} places; it must be exactly one"
    end
  end
end
