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
  # Static source checks in the spirit of `mobile_overflow_test.exs` and
  # `dark_mode_css_test.exs`.

  @shell Path.expand("../../lib/vutuv_web/live/shell_live.ex", __DIR__)
  @components_css Path.expand("../../assets/css/components.css", __DIR__)

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
