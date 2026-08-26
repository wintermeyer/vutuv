defmodule VutuvWeb.TouchZoomCssTest do
  use ExUnit.Case, async: true

  # iOS zooms the page in when a focused form field is under 16px and never
  # zooms back out (issue #1726). The fix is one declaration, and everything
  # that can go wrong with it is about WHERE it lives.
  #
  # The 14px arrives from three directions: `input_class/0` carries `text-sm`
  # (a Tailwind utility, ~40 kit forms including sign-up), `.editform` fields
  # are `0.875rem`, and the base `select` rule is 15px. Only the first decides
  # where the fix can go — `components.css` sits in the `components` layer,
  # which loses to the utilities layer WHATEVER its specificity, so the same
  # rule written down there is in the stylesheet, reads as if it applies, and
  # does nothing at all to the sign-up form. That is not a hypothetical: it is
  # how this fix was first written, and only a computed-style check in a
  # browser caught it (measured: the tag box moved to 16px, every kit input
  # stayed at 14px).
  #
  # So this is a static check in the spirit of `press_paint_css_test`. It
  # cannot measure a browser, but it holds the one thing a reader cannot see by
  # looking at the rule: that it is outside every cascade layer.

  @app_css Path.expand("../../assets/css/app.css", __DIR__)
  @components_css Path.expand("../../assets/css/components.css", __DIR__)
  @root_layout Path.expand(
                 "../../lib/vutuv_web/templates/layout/root.html.heex",
                 __DIR__
               )

  test "the 16px floor is in app.css, outside every cascade layer" do
    css = File.read!(@app_css)

    assert css =~ ~r/@media \(pointer: coarse\)/,
           "the touch font-size floor belongs in app.css (issue #1726)"

    assert css =~ ~r/@media \(pointer: coarse\) \{.*?font-size: 16px;.*?\}/s,
           "the floor must actually set 16px"
  end

  test "it is NOT in components.css, where it would lose to the utilities layer" do
    css = File.read!(@components_css)

    refute css =~ ~r/@media \(pointer: coarse\)/,
           """
           A `pointer: coarse` font-size rule in components.css cannot beat the
           `text-sm` utility that `input_class/0` puts on every kit input, so it
           silently does nothing to the sign-up form. It belongs in app.css,
           after @theme and outside every layer.
           """
  end

  test "the floor keys on the pointer, not on the viewport width" do
    css = File.read!(@app_css)

    [block] = Regex.run(~r/@media \(pointer: coarse\) \{.*?\n\}/s, css)

    refute block =~ ~r/(max|min)-width/,
           """
           A width breakpoint is the wrong axis: an iPad in landscape is wide and
           still zooms, and a narrow desktop window never did. Keep it on
           `pointer: coarse`.
           """
  end

  test "deliberate zoom is never taken away" do
    layout = File.read!(@root_layout)

    refute layout =~ "user-scalable",
           "user-scalable=no would stop the zoom and fail WCAG 1.4.4 (issue #1726)"

    refute layout =~ ~r/maximum-scale\s*=/,
           "maximum-scale is the same WCAG 1.4.4 failure by another spelling"
  end
end
