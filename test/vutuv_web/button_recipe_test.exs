defmodule VutuvWeb.ButtonRecipeTest do
  @moduledoc """
  Regression guard: the button recipe has exactly one owner.

  `VutuvWeb.UI.button/1` and `button_class/1` decide what a pressable control
  looks like — layout, 40px height, radius, padding, text size, colours. The
  failure this test exists for is not a wrong colour, it is **drift**: the
  recipe was copied by hand into 39 files, each copy dropping or adding a
  little (`inline-flex` here and not there, `px-4 py-2` beside `px-3 py-1.5`
  beside `px-3 py-1 text-xs`, four spellings of the quiet red remove), and the
  result was rows where a filled box, a bare word and a tinted pill stood side
  by side at three different heights — reported on
  `/system/fediverse/account/:id`, and true of a dozen other rows.

  So the rule this pins is mechanical: **outside `ui.ex`, nothing spells out a
  button's fill and padding together.** Reach for `<.button>`, or
  `button_class/1` for the rare anchor the component cannot render.

  It names the **effect**, not the spellings: a fill (`bg-<colour>-<shade>`)
  plus horizontal *and* vertical padding plus `font-semibold`, in any order.
  Nine literal substrings were the first attempt and were porous three ways —
  `"rounded-md px-3 py-1.5 text-sm font-semibold bg-brand-600 text-white"`
  writes the colour last and matched none of them, nothing in this repo sorts
  Tailwind classes, and a paste from the owner's own rendered string puts the
  geometry first.

  It reads `assets/js` too. Two dialogs are built in JavaScript (the avatar and
  post-photo crop modals), they held four more copies of the recipe, and being
  outside `lib/` is exactly why nobody noticed they had missed the 40px height.

  Calibrated against the tree this sweep started from: over `origin/main` at
  f63812fa this scan names 54 lines — 50 across 30 files under `lib/vutuv_web`,
  4 in the two crop dialogs under `assets/js` — and here it names none. (The
  literal-substring version it replaced counted 63 lines in 39 files: a wider
  net on the spellings that existed, a narrower one on the spellings that did
  not, which is the trade this predicate reverses.)
  """
  use ExUnit.Case, async: true

  # A fill, in any of the six palettes a button has ever worn here — and only an
  # UNPREFIXED one. `hover:bg-slate-100` on a control with no resting fill is a
  # hover tint, which `ghost` and `danger-ghost` are made of; treating it as a
  # fill flagged every quiet button in the tree.
  @fill ~r/(?<![-\w:])bg-(?:brand|slate|red|rose|amber|emerald)-\d{2,3}\b/
  @padding_x ~r/\bpx-\d/
  @padding_y ~r/\bpy-\d/

  # A label is not a control. Two shapes carry a fill and read as text: the round
  # status pill (`status_pill/1` and its callers) and the flat badge, both of
  # which sit at `py-0.5`/`py-1` because nobody presses them. That cut-off is the
  # honest one available from a class list alone — a badge and a genuinely tiny
  # button are indistinguishable here — and the smallest real button left in the
  # tree is `py-1.5`, so nothing pressable hides under it.
  @label ~r/\brounded-full\b|\bpy-(?:0\.5|1)\b/

  # The tab family, which this sweep did not take. `post_filter_tab_class/1`
  # (the feed's post-type strip), the audience builder's `mode_tab_class/1` and
  # the shell's nav item are one control drawn three ways, and folding them into
  # the button recipe is the next unit of work rather than a line to sneak in
  # here. Named explicitly so the guard does not quietly bless them: a fourth
  # tab spelling still fails.
  @unswept [
    {"lib/vutuv_web/components/post_components.ex", "bg-brand-100 px-3 py-2.5"},
    {"lib/vutuv_web/live/admin/newsletter_group_live.ex", "rounded-md px-3 py-1.5"},
    {"lib/vutuv_web/live/shell_live.ex", "rounded-md px-3 py-2 bg-brand-50"}
  ]

  # `ui.ex` is the owner and holds the only copy by design; `util.js` holds the
  # one deliberate JS copy, for the dialogs JavaScript builds itself. The CSS
  # twin of the recipe lives in components.css and is pinned separately below.
  @owners ["lib/vutuv_web/components/ui.ex", "assets/js/util.js"]

  test "no file outside the UI kit spells out a button's fill and padding" do
    offenders =
      for path <- sources(),
          path not in @owners,
          line <- lines_with(path, "font-semibold"),
          recipe?(line),
          not unswept?(path, line),
          do: "#{path}: #{String.trim(line)}"

    assert offenders == [],
           """
           These lines spell out the button recipe by hand instead of taking it
           from `VutuvWeb.UI`. Use `<.button variant="…">`, or `button_class/1`
           where a component will not do:

           #{Enum.map_join(offenders, "\n", &("  " <> &1))}
           """
  end

  test "every variant carries the shared geometry" do
    for variant <- ~w(primary secondary ghost danger danger-ghost) do
      assert String.starts_with?(VutuvWeb.UI.button_class(variant), VutuvWeb.UI.button_base()),
             "the #{variant} button must be built on button_base/0"
    end
  end

  # The 40px target is what makes "one size" true for a row that mixes a plain
  # label with an icon button: padding alone leaves them a few pixels apart.
  test "the shared geometry is a 40px touch target, chips included" do
    assert VutuvWeb.UI.button_base() =~ "min-h-10"
    assert VutuvWeb.UI.filter_chip_class(false) =~ "min-h-10"
  end

  # Two implementations of one recipe: kit pages compose `button_base/0`,
  # classic pages get `.button` from components.css. They have to agree on the
  # height or the site has two button sizes depending on which page you are on.
  test "the classic .button matches the kit's height" do
    css = File.read!("assets/css/components.css")
    [base_rule] = Regex.run(~r/^\.button,\n.*?\n\}/ms, css)

    assert base_rule =~ "min-height: 2.5rem",
           ".button in components.css must be the same 40px as button_base/0"
  end

  defp recipe?(line) do
    not Regex.match?(@label, line) and Regex.match?(@fill, line) and
      Regex.match?(@padding_x, line) and Regex.match?(@padding_y, line)
  end

  defp unswept?(path, line) do
    Enum.any?(@unswept, fn {p, marker} -> p == path and String.contains?(line, marker) end)
  end

  defp sources do
    Path.wildcard("lib/vutuv_web/**/*.{ex,heex}") ++ Path.wildcard("assets/js/*.js")
  end

  # `font-semibold` is in every spelling of the recipe and in 0.5 % of the
  # tree's lines, so it is the prefilter that keeps this test at milliseconds
  # rather than seconds — the first version ran four regexes over all 116,000
  # lines and took 5.7 of the suite's seconds on its own.
  defp lines_with(path, marker) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, marker))
  end
end
