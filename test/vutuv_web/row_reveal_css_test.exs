defmodule VutuvWeb.RowRevealCssTest do
  use ExUnit.Case, async: true

  # The filter band's "Only" is a per-row shortcut that shows while the pointer
  # is on the row. Written the obvious way — a resting `opacity: 0` with a
  # `:hover` rule to undo it — it is invisible forever on a phone, which reaches
  # the very same card through the feed's filter sheet and has no hover to
  # reveal anything with. So the resting state has to be VISIBLE and the hiding
  # has to sit inside `@media (hover: hover)`, never the other way round.
  #
  # That inversion is easy to "tidy up" back into the broken shape, because the
  # broken shape is shorter and looks identical on the machine it is written on.
  # Hence this check.
  #
  # A static source check in the spirit of `press_paint_css_test` and
  # `rail_drag_css_test`: it cannot measure a browser, but it holds the shape.

  @css Path.expand("../../assets/css/components.css", __DIR__)

  defp block do
    css = File.read!(@css)
    [_, rest] = String.split(css, ".row-reveal-host .row-reveal {", parts: 2)
    [body, _] = String.split(rest, "\n.skeleton {", parts: 2)
    ".row-reveal-host .row-reveal {" <> body
  end

  test "the resting state is visible and only a hover-capable device hides it" do
    body = block()

    assert body =~ "@media (hover: hover)",
           "without the query a phone gets the resting state, so it must be the visible one"

    [before_query, inside] = String.split(body, "@media (hover: hover)", parts: 2)

    refute before_query =~ "opacity: 0",
           "a resting opacity of 0 outside the query leaves touch with no way to see the control"

    assert inside =~ "opacity: 0",
           "the hiding belongs to the pointer device, so it lives inside the query"
  end

  test "it hides with opacity, so the row cannot reflow under the cursor" do
    body = block()

    # `display: none` would work and would move the count sideways the moment
    # the word appeared, which is exactly the jump this control sits still to
    # avoid — and it would take the shortcut out of the accessibility tree,
    # where a screen reader should still find it without hovering.
    refute body =~ "display: none",
           "hiding by display reflows the row and drops the control from the a11y tree"

    assert body =~ "pointer-events: none",
           "an invisible button is still hit-testable, so the pointer has to be told"
  end

  test "keyboard reaches it without a pointer" do
    body = block()

    assert body =~ ":focus-within",
           "tabbing into the row is what reveals the shortcut for a keyboard reader"

    assert body =~ ":focus-visible",
           "and the tab that lands on the button itself has to reveal it too"
  end
end
