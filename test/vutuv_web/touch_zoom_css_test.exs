defmodule VutuvWeb.TouchZoomCssTest do
  use ExUnit.Case, async: true

  # iOS zooms the page in when a focused form field is under 16px and never
  # zooms back out (issue #1726). The fix is one declaration, and everything
  # that can go wrong with it is about WHERE it lives — the block's own comment
  # in `assets/css/app.css` carries the full reasoning.
  #
  # That is not a hypothetical: the fix was first written in `components.css`,
  # which sits in the `components` layer and therefore loses to the `text-sm`
  # utility that `input_class/0` puts on every kit input. The rule was in the
  # stylesheet, read as if it applied, and moved only the tag box; every kit
  # input stayed at 14px until a computed-style check in a browser caught it.
  #
  # So this is a static check in the spirit of `press_paint_css_test`. It cannot
  # measure a browser, but it holds the one thing a reader cannot see by looking
  # at the rule: that it is outside every cascade layer. It holds that in two
  # halves, because "unlayered" is not a property of a single declaration — the
  # floor is in `app.css` and not in the layered `components.css`, AND `app.css`
  # opens no `@layer` block of its own for it to fall into. Asserting only the
  # file would pass on a rule someone had wrapped in `@layer components { … }`
  # right there, which is the same silent failure by another route.
  #
  # The viewport half of the contract — that no `user-scalable=no` ever appears
  # — lives with the rest of the viewport assertions in
  # `web_app_manifest_test.exs`, which reads the rendered `content="…"` value
  # rather than the layout's source text.

  @app_css Path.expand("../../assets/css/app.css", __DIR__)
  @components_css Path.expand("../../assets/css/components.css", __DIR__)

  test "the 16px floor is in app.css, keyed on the pointer and not on a width" do
    css = File.read!(@app_css)

    assert css =~ ~r/@media \(any-pointer: coarse\) \{[^}]*?font-size: 16px;.*?\n\}/s,
           """
           The touch font-size floor belongs in app.css, outside every cascade
           layer, keyed on `any-pointer: coarse` with no width condition: an
           iPad in landscape is wide and still zooms, a narrow desktop window
           never did — and `pointer` alone would answer `fine` on that iPad the
           moment a keyboard is attached (issue #1726).
           """
  end

  test "app.css opens no cascade layer, so the floor cannot fall into one" do
    # `@import … layer(components)` on line 13 puts components.css INTO a layer
    # and is not an `@layer` block, so it does not match. Everything app.css
    # itself declares is unlayered, which is exactly what makes it the one place
    # that beats a utility — and what the test above relies on without saying.
    refute File.read!(@app_css) =~ ~r/@layer[\s{]/,
           """
           Something in app.css now opens a cascade layer. Anything inside it
           loses to the utilities layer whatever its specificity, so the 16px
           touch floor (issue #1726) would be back to reading as if it applied
           and doing nothing to the sign-up form. Keep app.css unlayered, or
           move this test's assertion to the floor's own block.
           """
  end

  # components.css has one coarse-pointer block of its own, for `touch-action`
  # (which needs no unlayered placement — it has no utility to beat). These two
  # assertions pin what may and may not be in it.
  #
  # Both read EVERY such block, not the first: a stray second one further down
  # the file is exactly how the font-size floor would come back, and matching
  # only the first would never see it. Likewise the refute is scoped to those
  # blocks rather than to the whole file — `.reorder__btn` legitimately sets a
  # 16px of its own.
  defp coarse_blocks(path) do
    ~r/@media \(any-pointer: coarse\) \{.*?\n\}/s
    |> Regex.scan(File.read!(path))
    |> List.flatten()
  end

  test "the coarse-pointer block in components.css carries the touch-action opt-out" do
    assert Enum.any?(coarse_blocks(@components_css), &(&1 =~ "touch-action: manipulation;")),
           "the double-tap-zoom opt-out belongs inside a coarse-pointer query"
  end

  test "the font-size floor is NOT there, where it would lose to the utilities layer" do
    refute Enum.any?(coarse_blocks(@components_css), &(&1 =~ "font-size")),
           """
           A font-size rule in components.css cannot beat the `text-sm` utility
           that `input_class/0` puts on every kit input, so it silently does
           nothing to the sign-up form. It belongs in app.css, after @theme and
           outside every layer.
           """
  end
end
