defmodule VutuvWeb.LineClampCssTest do
  use ExUnit.Case, async: true

  # The height clamps that cut *formatted* Markdown to N whole lines — the post
  # teasers under a suggested profile (`.teaser-clamp`) and the post a
  # /notifications row quotes (`.notif-clamp`) — must state their budget
  # WITHOUT the `lh` unit, and must own both halves of the arithmetic (the line
  # height and the box height) in one rule.
  #
  # Why: `lh` is not portable. Safari resolves `1lh` against the INHERITED
  # line-height — the 24px the surrounding card passes down — instead of the
  # element's own 20px, so `max-height: calc(3 * 1lh)` measured 72px there while
  # Chrome measured the intended 60px. Three whole lines still fit, and 12px of
  # the fourth peeked into the box, cut through the middle of its letters
  # (reported 2026-07-30 for the "Who to follow" card, in Safari on macOS).
  # A clamp expressed in one absolute unit cannot drift apart that way.
  #
  # The second half of the arithmetic is the call site: while the text size and
  # line height came from Tailwind utilities (`text-sm leading-5`) and the box
  # height from the stylesheet, swapping one utility for another (`text-base`)
  # would silently make the box no longer a whole number of lines. So the rule
  # sets font-size and line-height itself and the markup must not re-declare
  # either.
  #
  # A static source check in the spirit of `dark_mode_css_test.exs` — it cannot
  # measure a browser, but it does hold the shape that makes the measurement
  # come out right in every engine.

  @components_css Path.expand("../../assets/css/components.css", __DIR__)

  @clamps [
    %{
      label: ~s(the "Who to follow" post teaser),
      class: "teaser-clamp",
      source: Path.expand("../../lib/vutuv_web/views/user_html.ex", __DIR__)
    },
    %{
      label: "the /notifications post quote",
      class: "notif-clamp",
      source: Path.expand("../../lib/vutuv_web/live/notification_live/index.ex", __DIR__)
    }
  ]

  defp components_css, do: File.read!(@components_css)

  # The declarations of `.<class> { … }` itself (not the compound
  # `.<class>.markdown *` helpers, which the trailing `\s*\{` excludes).
  defp rule_body(class) do
    case Regex.run(~r/\.#{Regex.escape(class)}\s*\{([^}]*)\}/, components_css()) do
      [_, body] -> body
      nil -> flunk("components.css has no `.#{class} { … }` rule")
    end
  end

  # Every `class="…"` attribute in the markup that puts the clamp on an element
  # (newlines excluded, so prose mentioning the class in a comment can't match).
  defp class_lists(source, class) do
    source
    |> File.read!()
    |> then(&Regex.scan(~r/class="([^"\n]*\b#{Regex.escape(class)}\b[^"\n]*)"/, &1))
    |> Enum.map(fn [_, list] -> list end)
  end

  for clamp <- @clamps do
    @clamp clamp

    test "#{clamp.label} clamps in one absolute unit, never `lh`" do
      body = rule_body(@clamp.class)

      refute body =~ ~r/\d\s*lh\b/,
             "`.#{@clamp.class}` must not size its clamp with the `lh` unit: Safari " <>
               "resolves it against the inherited line-height, not the element's own, " <>
               "so the box grows past N lines and the next line peeks in"

      assert [_, line_var] = Regex.run(~r/line-height:\s*var\((--[a-z-]+)\)/, body),
             "`.#{@clamp.class}` must set its own `line-height` from a custom property, " <>
               "so the box height below can be counted in exactly that unit"

      assert body =~ ~r/max-height:\s*calc\([^;]*var\(#{line_var}\)/,
             "`.#{@clamp.class}`'s `max-height` must be a multiple of `var(#{line_var})` — " <>
               "the same line unit it sets above"

      assert body =~ ~r/#{line_var}:\s*[\d.]+rem/,
             "`#{line_var}` must be an absolute rem length: a unitless ratio makes a " <>
               "line box depend on the font size a descendant happens to have"

      assert body =~ ~r/font-size:\s*[\d.]+rem/,
             "`.#{@clamp.class}` must set its own `font-size` too, or a descendant's " <>
               "size (the legacy `p { font-size: 15px }`) renders taller lines than the " <>
               "box counts"
    end

    test "#{clamp.label} markup leaves the text size and line height to the stylesheet" do
      lists = class_lists(@clamp.source, @clamp.class)

      assert lists != [], "expected #{@clamp.source} to render `#{@clamp.class}`"

      for list <- lists do
        refute list =~ ~r/\btext-(xs|sm|base|lg|xl|\d|\[)/,
               "`#{@clamp.class}` owns its font size in components.css; the class list " <>
                 "`#{list}` re-declares it, and a size that no longer matches the clamp's " <>
                 "line unit shows a sliver of the next line"

        refute list =~ ~r/\bleading-/,
               "`#{@clamp.class}` owns its line height in components.css; the class list " <>
                 "`#{list}` re-declares it, which breaks the box-height arithmetic"
      end
    end
  end

  # A height clamp cuts silently: unlike `-webkit-line-clamp` it paints no
  # ellipsis, so a teaser just stops mid-sentence. The "…" is therefore drawn
  # by the stylesheet, over the last visible line, on a blend of the tile's own
  # background — and it must be **gated on `is-clamped`**, the class app.js
  # sets only when the body really overflows. An unconditional `::after` would
  # put a "…" behind every short teaser that never got cut (the shape of issue
  # #880, where a "Read more" showed on posts that were fully visible).
  test "the teaser's truncation ellipsis is painted only while the body is clamped" do
    css = components_css()

    assert [_, selector] = Regex.run(~r/(\.teaser[^{}]*::after)\s*\{[^}]*content:\s*"…"/, css),
           ~s(components.css must paint a `content: "…"` on the teaser clamp — ) <>
             "a height clamp shows no ellipsis of its own"

    assert selector =~ "is-clamped",
           "the ellipsis selector (`#{selector}`) must require `is-clamped`, or a short " <>
             "teaser that was never cut gets a \"…\" too"

    assert css =~ ~r/\.teaser-tile[^{}]*\{[^}]*--teaser-bg:/,
           "`.teaser-tile` must define `--teaser-bg`: the ellipsis blends the end of the " <>
             "last line into the tile's background, and that colour changes on hover and " <>
             "in dark mode, so both sides have to read the same custom property"
  end
end
