defmodule VutuvWeb.RailDragCssTest do
  use ExUnit.Case, async: true

  # Dragging a feed-rail card past a card taller than the window was impossible,
  # and the reason is arithmetic rather than feel: the drop position is decided
  # by each card's vertical MIDPOINT (`rowAfter` in the Reorder hook), and the
  # midpoint of a 700px card leaves the viewport long before its top edge does.
  # There is then no pointer position that names it, however patiently you drag.
  #
  # Two things answer it, and each covers what the other cannot: a cap on how
  # far into a row the pointer must travel, so a tall neighbour behaves like a
  # short one; and a page that scrolls itself at the window edges, for a row
  # whose top edge is off screen whatever the cap does.
  #
  # The third rule below is the expensive one. The first attempt folded every
  # card to its heading for the length of the drag, which read beautifully and
  # cost Safari drag-and-drop entirely: mutating layout (or scrolling) inside
  # `dragstart` cancels the native drag session in WebKit. The check therefore
  # guards the *absence* of DOM work in that handler, which is the kind of thing
  # a later "small improvement" reintroduces without knowing what it costs.
  #
  # A static source check in the spirit of `press_paint_css_test` — it cannot
  # measure a browser, but it holds the shape.

  @js Path.expand("../../assets/js/app.js", __DIR__)

  # The Reorder hook's body, so a match cannot wander into another hook.
  defp hook do
    js = File.read!(@js)
    [_, rest] = String.split(js, "  Reorder: {", parts: 2)
    [body, _] = String.split(rest, "\n  },\n", parts: 2)
    body
  end

  test "a tall row costs the pointer no more than the cap" do
    body = hook()

    assert body =~ "const TALL_CAP =",
           "the cap is what makes a card taller than the window reachable"

    assert body =~ "Math.min(box.height / 2, TALL_CAP)",
           "the reference line is the midpoint, capped — not the bare midpoint"
  end

  test "the edge scroll runs on its own frame loop, not on dragover" do
    body = hook()

    # A pointer held still at the window edge stops firing `dragover` in some
    # browsers — which is the moment the reader is waiting for the page to move.
    assert body =~ "requestAnimationFrame(stepEdgeScroll)"
    assert body =~ "cancelAnimationFrame(edgeFrame)", "and it has to stop on dragend"
  end

  test "the grip is armed by hovering it, never by the press itself" do
    body = hook()

    # The browser decides whether a press begins a drag as the press arrives, so
    # `draggable` set inside `pointerdown` comes too late for that same press:
    # the first click only armed the row and the second one dragged it — every
    # card needed two clicks (reported 2026-08-28).
    assert body =~ ~s|list.addEventListener("pointerover", arm)|

    assert body =~ ~s|list.addEventListener("pointermove", arm)|,
           "a LiveView patch strips the attribute, so moving on the grip re-arms it"

    refute body =~ ~s|list.addEventListener("pointerdown"|,
           "arming on the press is the bug this test exists for"

    # And it has to survive the drag it started, or a second drag needs a second
    # press for the same reason.
    assert body =~ "Deliberately no disarm here"
  end

  test "dragstart changes no geometry, or WebKit cancels the drag" do
    [dragstart, _] =
      hook()
      |> String.split(~s|list.addEventListener("dragstart"|, parts: 2)
      |> List.last()
      |> String.split(~s|list.addEventListener("dragend"|, parts: 2)

    for forbidden <- ["scrollBy", "scrollTo", "scrollIntoView", "classList.add(\"is-reordering"] do
      refute dragstart =~ forbidden,
             """
             `dragstart` must not move the page or relayout the rail: a WebKit \
             drag session dies on it and Safari loses drag-and-drop outright \
             (2026-08-28). Whatever this is, do it before the drag or not at all.\
             """
    end
  end
end
