defmodule VutuvWeb.MobileTabBarCssTest do
  use ExUnit.Case, async: true

  # Regression test for the phone tab bar drifting away from the bottom edge.
  #
  # Reported on an iPhone (iOS 26 Safari, 2026-08-14): the bar sits correctly
  # at the bottom on load and then hangs in the middle of the screen once the
  # page is scrolled, with the feed running on underneath it. That is the
  # widely reported iOS 26 regression in which WebKit mispositions the
  # compositing layer of a `position: fixed` bar while scrolling. We cannot fix
  # Safari, but the reported cases share two things this app was handing it,
  # and both are cheap to stop doing:
  #
  #   * a **blurred, translucent** bar. `backdrop-filter` forces the fixed
  #     layer to be re-rasterized against the scrolling content on every frame,
  #     which is exactly the path that goes wrong; an opaque bar is composited
  #     once. (The frosted bars of the sites in the bug reports are the tell.)
  #   * `html { height: 100% }` with content that overflows it, a long-standing
  #     trigger for iOS treating the html box, rather than the viewport, as the
  #     anchor of a `bottom: 0` fixed element — which drifts the bar upward by
  #     exactly the scroll offset.
  #
  # The `html` rule existed only so `body.stretch` (the account-deletion page)
  # could fill the screen; a viewport min-height on `body` does that without a
  # global height on the document element.
  #
  # The safe-area tests below come from the second report about this same bar
  # (issue #1464, the installed web app): once the page paints edge to edge,
  # the bar has to hand the home indicator's strip back to the system and keep
  # its outer tabs off the screen edges.
  #
  # Static source checks in the spirit of `mobile_overflow_test.exs` and
  # `dark_mode_css_test.exs`.

  @shell Path.expand("../../lib/vutuv_web/live/shell_live.ex", __DIR__)
  @components_css Path.expand("../../assets/css/components.css", __DIR__)
  @layout Path.expand("../../lib/vutuv_web/templates/layout/app.html.heex", __DIR__)

  # Comments name selectors and properties; strip them so the assertions only
  # ever see real rules.
  defp components_css do
    Regex.replace(~r{/\*.*?\*/}s, File.read!(@components_css), "")
  end

  # The class list of the fixed mobile tab bar in ShellLive.
  defp tab_bar_classes do
    case Regex.run(~r/"(fixed inset-x-0 bottom-0[^"]*)"/, File.read!(@shell)) do
      [_, classes] ->
        classes

      _ ->
        flunk("""
        No `fixed inset-x-0 bottom-0 ...` class list found in #{@shell}.
        That is the mobile bottom tab bar; if it moved, move this test with it.
        """)
    end
  end

  # The whole `class={[...]}` list the bar is rendered with, tab_bar_classes/0
  # being only its first string. The safe-area utilities live in the strings
  # after it.
  defp tab_bar_class_list do
    [_, list] =
      Regex.run(~r/class=\{\[\s*"fixed inset-x-0 bottom-0(.*?)\]\}/s, File.read!(@shell))

    list
  end

  test "the phone tab bar is opaque (no blurred, translucent fixed layer)" do
    classes = tab_bar_classes()

    refute classes =~ "backdrop-blur",
           """
           The mobile tab bar must not carry `backdrop-blur`: a blurred
           backdrop on a `position: fixed` element is what iOS 26 Safari
           mispositions mid-scroll, leaving the bar hanging in the middle of
           the screen.
           """

    refute classes =~ ~r{bg-white/},
           "the mobile tab bar needs an opaque `bg-white`, not a translucent one"

    refute classes =~ ~r{dark:bg-slate-900/},
           "the mobile tab bar needs an opaque `dark:bg-slate-900`, not a translucent one"

    assert classes =~ "bg-white", "the mobile tab bar still needs its light background"

    assert classes =~ "dark:bg-slate-900",
           "the mobile tab bar still needs its dark background"
  end

  # Issue #1464: on a phone with a home indicator the bottom strip of the
  # screen is the system's, not ours. The bar therefore grows by that inset and
  # pads the same amount away, so its tabs keep their full 4rem above it — and
  # whatever reserves room for the bar has to reserve the grown height, or the
  # page scrolls underneath it. The horizontal padding is the other half of the
  # report: the outer two tabs sat hard against the screen edges, which in
  # landscape is where the sensor housing is.
  test "the phone tab bar reserves the home indicator's strip" do
    classes = tab_bar_class_list()

    assert classes =~ "h-[calc(4rem+env(safe-area-inset-bottom))]",
           "the bar must grow by the bottom inset, or its labels sit in the indicator's strip"

    assert classes =~ "pb-[env(safe-area-inset-bottom)]",
           "the bar must pad that inset away again, or the tabs lose 4rem of height to it"

    refute classes =~ ~r/\bh-16\b/,
           "a fixed `h-16` would fight the grown height (both set height, utilities tie)"
  end

  test "the outer tabs keep clear of the screen edges" do
    classes = tab_bar_class_list()

    assert classes =~ "pl-[max(0.75rem,env(safe-area-inset-left))]"
    assert classes =~ "pr-[max(0.75rem,env(safe-area-inset-right))]"
  end

  test "the page reserves the bar's grown height below its content" do
    layout = File.read!(@layout)

    assert layout =~ "pb-[calc(6rem+env(safe-area-inset-bottom))]",
           """
           <main> and the footer clear the tab bar by its own height plus air.
           When the bar grew by the home-indicator inset, that padding had to
           grow with it, or the last card sits behind the bar.
           """
  end

  test "the document element carries no global height, and body fills the viewport" do
    css = components_css()

    refute css =~ ~r/(?:^|[,}])\s*html\s*\{[^}]*(?<!min-)height\s*:\s*100%/,
           """
           `html { height: 100% }` must stay gone: with content overflowing it,
           iOS anchors a `bottom: 0` fixed element to the html box instead of
           the viewport, so the phone tab bar drifts up with the scroll.
           """

    # There is more than one bare `body` rule (element defaults, stretch
    # layout); the viewport height may live in any of them.
    declarations =
      ~r/(?:^|[,}])\s*body\s*\{([^}]*)\}/
      |> Regex.scan(css, capture: :all_but_first)
      |> List.flatten()
      |> Enum.join(";")

    assert declarations =~ ~r/min-height\s*:\s*100dvh/,
           """
           `body` must keep a viewport min-height (`100dvh`), or `body.stretch`
           (the account-deletion page) no longer fills the screen once the
           `html { height: 100% }` it used to resolve against is gone.
           """
  end
end
