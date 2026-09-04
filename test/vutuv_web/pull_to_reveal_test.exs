defmodule VutuvWeb.PullToRevealTest do
  use ExUnit.Case, async: true

  # Pulling the feed down to reveal the waiting posts did nothing at all on an
  # iPhone, and everything in Chrome — including under Chrome's own mobile
  # emulation with real touch input, which is why it passed every check here.
  # The difference is not the gesture, it is when the listener that cancels it
  # is handed over. WebKit works out at `touchstart` whether a touch sequence
  # may block the main thread; a `touchmove` listener added inside that handler
  # is not part of the answer (WebKit bug 184250, and 185656 for the moves that
  # stay uncancellable after its fix), so every move of the gesture arrived
  # with `cancelable: false`, the hook handed the touch back on the first one,
  # and the page just rubber-banded.
  #
  # The same shape has cost this codebase a feature once before: `draggable`
  # set inside `pointerdown` came too late for that press, and the rail needed
  # two clicks per drag (see `rail_drag_css_test`). The listener has to stand
  # before the finger lands.
  #
  # A static source check — it cannot drive WebKit, but it holds the one thing
  # that separates the working code from the broken code. Measured against both
  # (Chrome, `DOMDebugger.getEventListeners` on `document`, a post waiting):
  # before, `touchmove` was absent until the finger was already down; after, it
  # stands there blocking, and only while a pill waits.

  @js Path.expand("../../assets/js/pull_to_reveal.js", __DIR__)

  defp source, do: File.read!(@js)

  # One function's body, so a match cannot wander into a neighbour.
  defp block(marker, closing) do
    js = source()
    assert js =~ marker, "#{marker} is gone — this test is now guarding nothing"
    [_, rest] = String.split(js, marker, parts: 2)
    [body, _] = String.split(rest, closing, parts: 2)
    body
  end

  test "the cancelling listener is not handed over inside touchstart" do
    refute block("this.onStart = (event) => {", "\n    }\n") =~ "addEventListener",
           """
           `touchstart` is too late to register the `touchmove` listener that \
           cancels the pull: WebKit has decided by then, and on an iPhone the \
           gesture draws nothing while the page rubber-bands (bug 184250). \
           Register it before the finger lands.\
           """
  end

  test "it is registered blocking, or preventDefault can hold nothing" do
    assert source() =~ ~s|addEventListener("touchmove", this.onMove, { passive: false })|,
           "a passive listener may not call preventDefault, so the page would scroll under the pull"
  end

  test "and it follows the pill, so an ordinary scroll never waits on it" do
    body = block("  sync() {", "\n  },\n")

    assert body =~ "pill()", "what arms the gesture is a post waiting, nothing else"
    assert body =~ ~s|addEventListener("touchmove"|
    assert body =~ ~s|removeEventListener("touchmove"|, "a feed with nothing waiting pays nothing"
  end
end
