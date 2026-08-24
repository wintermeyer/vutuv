defmodule VutuvWeb.PressPaintCssTest do
  use ExUnit.Case, async: true

  # Four bars answer their own press — the /feed source tabs, the
  # /notifications filter tabs, the top bar's nav and the phone's bottom tab
  # bar — and there is one set of rules behind all of them.
  #
  # The pull the other way is strong: they look different, live in different
  # modules and use different controls (a `phx-click` button, a `<.link
  # patch>`, a plain link), so the obvious move when a fifth one arrives is to
  # copy the block and re-tune it. Then they drift, the delay is a different
  # number on each page, and a fix has to be found four times — which is
  # exactly what happened to `.notif-clamp` and `.teaser-clamp`.
  #
  # So the shape is: one vocabulary of data attributes with no page's name in
  # it, one place for the timing, and colour as the single thing a bar names
  # for itself. A static source check in the spirit of `line_clamp_css_test`:
  # it cannot measure a browser, but it holds the shape.

  @css Path.expand("../../assets/css/app.css", __DIR__)
  @js Path.expand("../../assets/js/app.js", __DIR__)
  @feed Path.expand("../../lib/vutuv_web/live/post_live/feed.ex", __DIR__)
  @notifications Path.expand("../../lib/vutuv_web/live/notification_live/index.ex", __DIR__)
  @shell Path.expand("../../lib/vutuv_web/live/shell_live.ex", __DIR__)

  test "the threshold is configured once and read by name" do
    css = File.read!(@css)

    assert [_] = Regex.scan(~r/--press-pending-delay:\s*\d+ms;/, css),
           "the dim delay belongs on :root in app.css, exactly once"

    assert css =~ "transition-delay: var(--press-pending-delay);",
           "the dim rule must read the shared knob, not carry its own number"

    refute css =~ ~r/transition-delay:\s*\d/,
           "a literal delay beside the knob means one bar stopped following it"
  end

  test "the paint is written once, for whatever bar wears it" do
    css = File.read!(@css)

    assert [_] =
             Regex.scan(
               ~r/^\[data-filter-tab\]\.phx-click-loading,\n\[data-nav-item\]\[data-nav-pressing\] \{/m,
               css
             ),
           "one rule paints a pressed control; a second copy is a bar going its own way"

    # A bar picks its palette, never its own rule: the properties are the seam.
    assert css =~ "background-color: var(--press-on-bg);"
    assert css =~ ~s|[data-filter-bar="track"] [data-filter-tab] {|
    assert css =~ "[data-nav-bar] [data-nav-item] {"
    assert css =~ ~s|[data-nav-bar="tabs"] [data-nav-item] {|

    # Filter buttons say `aria-pressed`, every link says `aria-current`.
    # Dropping either half leaves that bar with two lit pills mid-flight.
    assert css =~ ~s|:is([aria-pressed="true"], [aria-current="page"])|
  end

  test "every palette a two-attribute selector sets is re-declared for dark mode" do
    [_light, dark] =
      String.split(File.read!(@css), "@media (prefers-color-scheme: dark)", parts: 2)

    # A (0,2,0) light rule survives a (0,1,0) dark one whatever the order, so a
    # dark block that only redeclares the bare `[data-nav-item]` default leaves
    # the top bar painting a brand-50 pill on a dark bar — from a stylesheet
    # that reads as if it had handled dark mode.
    for selector <- [
          ~s|[data-filter-bar="track"] [data-filter-tab]|,
          "[data-nav-bar] [data-nav-item]",
          ~s|[data-nav-bar="tabs"] [data-nav-item]|
        ] do
      assert dark =~ selector, "#{selector} keeps its light palette in dark mode"
    end
  end

  test "the nav press survives a patch of the shell it lives in" do
    js = File.read!(@js)

    # Both navs are inside ShellLive: an unread badge ticking walks these nodes
    # and morphdom drops whatever the server did not render. Without this the
    # paint vanishes mid-load, rarely and unreproducibly.
    assert js =~ "onBeforeElUpdated(from, to) {",
           "the LiveSocket needs a dom hook that carries the press mark across a patch"

    assert js =~ "if (from.hasAttribute(NAV_PRESSING)) to.setAttribute(NAV_PRESSING, \"\")"

    # A bfcache restore hands the old document back mid-press.
    assert js =~ ~s|window.addEventListener("pageshow"|,
           "a press painted before a navigation must be cleared when the reader comes back"
  end

  # The other half of what a slow line sees: the document has arrived, and a
  # page whose data waits for the socket has nothing to show yet.
  test "the waiting placeholder is one class, and it holds still when asked to" do
    css = File.read!(Path.expand("../../assets/css/components.css", __DIR__))

    assert [_] = Regex.scan(~r/^\.skeleton \{/m, css),
           "one .skeleton definition; a per-page copy is how two of them drift"

    assert css =~ "@media (prefers-reduced-motion: reduce)"

    # It sits on a dark card too, and a light-grey outline is invisible there.
    [_light, dark] = String.split(css, "@media (prefers-color-scheme: dark)", parts: 2)
    assert dark =~ ".skeleton {", "the placeholder needs its dark-mode colour"
  end

  test "no bar names itself in the markers" do
    for path <- Path.wildcard(Path.expand("../../lib/vutuv_web/**/*.ex*", __DIR__)) do
      source = File.read!(path)

      refute source =~ ~r/data-(post|notif)-filter-(tab|scope)/,
             "#{Path.relative_to_cwd(path)} uses a per-page marker; the paint keys on " <>
               "`data-filter-tab` / `data-filter-scope` and would silently skip it"
    end
  end

  test "every host carries the markers the paint depends on" do
    for {path, markers} <- [
          {@feed, ["data-filter-scope", "data-filter-list"]},
          {@notifications, ["data-filter-scope", "data-filter-list"]},
          {@shell, ["data-nav-bar", "data-nav-item"]}
        ] do
      source = File.read!(path)
      where = Path.relative_to_cwd(path)

      for marker <- markers do
        assert source =~ marker, "#{where} must carry #{marker}"
      end
    end
  end
end
