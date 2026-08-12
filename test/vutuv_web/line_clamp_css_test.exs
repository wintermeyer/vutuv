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

  # `{selector, declarations}` for every rule in the stylesheet, comments
  # stripped first so a rule's preceding comment can't end up inside its
  # selector. A rule nested in an `@media` block is matched by its own
  # selector (the media condition ends at the brace the regex cannot cross).
  defp rules do
    components_css()
    |> String.replace(~r|/\*.*?\*/|s, "")
    |> then(&Regex.scan(~r/([^{}]+)\{([^{}]*)\}/, &1))
    |> Enum.map(fn [_, selector, body] -> {String.trim(selector), body} end)
  end

  defp selectors(selector), do: selector |> String.split(",") |> Enum.map(&String.trim/1)

  # Everything declared for the bare `.<class>` selector, joined — a shared base
  # rule (`.notif-clamp, .teaser-clamp { … }`) counts for both classes, which is
  # the point: the two clamps are one mechanism with two budgets.
  defp declarations(class) do
    case Enum.filter(rules(), fn {sel, _} -> ".#{class}" in selectors(sel) end) do
      [] -> flunk("components.css declares nothing for a bare `.#{class}` selector")
      matched -> Enum.map_join(matched, "\n", fn {_, body} -> body end)
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
      body = declarations(@clamp.class)

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

    # The budget is counted in line boxes, so everything inside the clamp has to
    # contribute whole lines and nothing else. Zeroing the spacing of the DIRECT
    # children only is not enough: a quoted post that opens with a `>` blockquote
    # nests its paragraph one level deeper, that `<p>` keeps `.markdown p`'s
    # `margin-bottom: 0.75em`, and the 10.5px push every following line down by
    # half a line — so the box ends mid-letter (measured on /notifications
    # 2026-07-30: lines at 1.5 / 21.5 / 41.5 / **72** / 92 in a 100px box). Same
    # for block padding, which a `<pre>` brings along.
    test "#{clamp.label} neutralises spacing at every depth, not just for its children" do
      neutralisers =
        Enum.filter(rules(), fn {sel, _} ->
          Enum.any?(selectors(sel), &(&1 =~ ~r/\.#{Regex.escape(@clamp.class)}\b.*\s\*$/))
        end)

      assert neutralisers != [],
             "components.css must have a `.#{@clamp.class}…  *` rule (a DESCENDANT " <>
               "selector, not `> *`), or nested blocks keep their margins"

      body = Enum.map_join(neutralisers, "\n", fn {_, decls} -> decls end)

      for property <- ["margin-block", "padding-block"] do
        assert body =~ ~r/#{property}:\s*0/,
               "the `.#{@clamp.class}` descendant rule must zero `#{property}`: a " <>
                 "paragraph inside a blockquote (or a padded `<pre>`) otherwise shifts " <>
                 "every line below it and the clamp cuts through the middle of one"
      end
    end
  end

  # A height clamp cuts silently: unlike `-webkit-line-clamp` it paints no
  # ellipsis, so an excerpt just stops mid-sentence. The "…" is therefore drawn
  # by the stylesheet, over the last visible line, on a blend of whatever
  # surface the excerpt sits on — and it must be **gated on `is-clamped`**, the
  # class app.js sets only when the body really overflows. An unconditional
  # `::after` would put a "…" behind every short excerpt that was never cut
  # (the shape of issue #880, where "Read more" showed on fully visible posts).
  test "both clamps paint the same truncation ellipsis, only while clamped" do
    ellipsis =
      Enum.filter(rules(), fn {_, decls} -> decls =~ ~s(content: "…") end)

    assert ellipsis != [],
           ~s(components.css must paint a `content: "…"` at the end of a clamped ) <>
             "excerpt — a height clamp shows no ellipsis of its own"

    assert length(ellipsis) == 1,
           "the ellipsis belongs in ONE rule shared by both clamps, not one per clamp"

    [{selector, decls}] = ellipsis
    parts = selectors(selector)

    for class <- Enum.map(@clamps, & &1.class) do
      assert Enum.any?(parts, &String.contains?(&1, class)),
             "`.#{class}` must be covered by the shared ellipsis rule (`#{selector}`): " <>
               "both excerpts are cut the same way, so they say so the same way"
    end

    for part <- parts do
      assert part =~ "is-clamped",
             "every half of the ellipsis selector must require `is-clamped` (`#{part}` " <>
               "does not), or an excerpt that was never cut gets a \"…\" too"
    end

    assert [_, bg_var] = Regex.run(~r/linear-gradient\(.*?var\((--[a-z-]+)[,)]/, decls),
           "the ellipsis must blend into a custom property, not a fixed colour: it sits " <>
             "on a tile or a notification row whose background changes with hover, " <>
             "unread state and dark mode"

    for surface <- [".teaser-tile", "[data-notification-row]"] do
      assert Enum.any?(rules(), fn {sel, decls} ->
               Enum.any?(selectors(sel), &String.starts_with?(&1, surface)) and
                 decls =~ "#{bg_var}:"
             end),
             "`#{surface}` must define `#{bg_var}`, or the blend behind the \"…\" is " <>
               "painted in the wrong colour on that surface"
    end
  end

  # ---------- The feed/profile post preview's bottom fade ----------
  #
  # The post previews clamp three ways — `.post-clamp` (line clamp),
  # `.post-clamp--wrap` and `.post-clamp--media` (height clamps, the variants
  # that can carry a float or an inline picture) — and all three end in a cut a
  # reader must be able to read as intentional.
  #
  # The two height clamps need it most, and used to be the two that went
  # without: their box is N line heights tall while the content carries
  # `.markdown p`'s paragraph margins, so the cut is NOT on a line boundary and
  # slices the last line through the middle of its letters. Reported 2026-08-12
  # on a feed post carrying a link screenshot (the wrap variant), where the
  # naked slice sat directly above "Weiterlesen".
  #
  # The reason they went without is the mechanism the fade used to have: an
  # absolutely positioned overlay gradient painted in the card's own colour,
  # anchored to the bottom of the preview. That spot is the cut only in the
  # line-clamp variant, where "Read more" rides the last line; the wrap/media
  # variants put "Read more" on its own in-flow line below the block, so the
  # overlay landed under that line and was switched off for them
  # (`.post-preview--wrap .post-preview__fade { display: none }`). Hence the
  # shape these tests hold: ONE fade, on the clamp body itself, in no particular
  # surface colour — so no variant can be forgotten and none can be excluded.

  defp preview_fades do
    Enum.filter(rules(), fn {sel, decls} ->
      decls =~ ~r/mask-image:/ and
        Enum.any?(selectors(sel), &String.contains?(&1, "post-preview"))
    end)
  end

  test "a clamped post preview fades out, and does so in exactly one rule" do
    assert preview_fades() != [],
           "components.css must fade the bottom of a clamped post preview — the height " <>
             "clamp variants cut through the middle of a line, and a naked slice reads " <>
             "as a rendering bug"

    assert length(preview_fades()) == 1,
           "the preview fade belongs in ONE rule covering every clamp variant, not one " <>
             "per variant: the wrap and media clamps were left without a fade for exactly " <>
             "as long as the fade was per-variant"
  end

  test "the preview fade rides the clamp body, so no clamp variant can be forgotten" do
    [{selector, _}] = preview_fades()

    assert selector =~ "[data-clamp-body]",
           "the fade must target `[data-clamp-body]` — the very element app.js measures — " <>
             "rather than naming `.post-clamp` / `--wrap` / `--media` one by one, or the " <>
             "next clamp variant ships without one (`#{selector}`)"

    for part <- selectors(selector) do
      assert part =~ "is-clamped" and part =~ "is-expanded",
             "every half of the fade selector must require `is-clamped` and exclude " <>
               "`is-expanded` (`#{part}` does not): a preview that was never cut would " <>
               "otherwise fade out its own last line (the shape of issue #880), and an " <>
               "expanded one would fade text the reader just asked to see"
    end
  end

  test "the preview fade is painted in no surface colour at all" do
    [{_, decls}] = preview_fades()

    refute decls =~ ~r/#(fff|ffffff|0f172a)\b/i,
           "the preview fade must not be a gradient into the card's colour: it also " <>
             "covers a floated image and a flat (uncarded) post surface, and a fixed " <>
             "colour is what forced the old overlay to be switched off per variant"

    for property <- ["-webkit-mask-image", "mask-image"] do
      assert decls =~ ~r/#{Regex.escape(property)}:\s*linear-gradient/,
             "the fade needs `#{property}` (both spellings — WebKit wants the prefixed " <>
               "one), so the content itself goes transparent instead of being painted over"
    end

    assert decls =~ ~r/transparent\s*\)/,
           "the mask must reach FULLY transparent at the box edge — that is what hides " <>
             "the half-line a height clamp slices off"
  end
end
