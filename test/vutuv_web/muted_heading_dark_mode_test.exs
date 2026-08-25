defmodule VutuvWeb.MutedHeadingDarkModeTest do
  @moduledoc """
  Dark mode follows the system with no toggle, so every text colour needs a
  `dark:` counterpart. `.claude/rules/design.md` states the rule for muted text
  and warns that `slate-500` is already borderline in light mode.

  `<.section_title>` shipped without its half: bare `text-slate-500` on a dark
  card is about 3.8:1, under the AA floor of 4.5:1, and `text-sm font-semibold`
  at 14px does not qualify as large text. Six hand-rolled copies of the same
  heading elsewhere in the tree had each added `dark:text-slate-400` for
  themselves, which is exactly the drift a shared component exists to prevent —
  and the reason to check the component rather than the call sites.

  Deliberately narrow: it keys on `slate-500` used as a **text** colour in the
  component kit, not on every `text-slate-*` in the app. The wider sweep was
  tried in an earlier pass and produced 78 false positives.
  """
  use ExUnit.Case, async: true

  @ui Path.expand("../../lib/vutuv_web/components/ui.ex", __DIR__)
  @design_rule Path.expand("../../.claude/rules/design.md", __DIR__)

  test "no muted text colour in the component kit is missing its dark half" do
    lines = @ui |> File.read!() |> String.split("\n")

    offenders =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} -> String.contains?(line, "text-slate-500") end)
      |> Enum.reject(fn {_line, n} -> dark_half_nearby?(lines, n) end)
      |> Enum.map(fn {line, n} -> "ui.ex:#{n}: #{String.trim(line)}" end)

    assert offenders == [],
           "muted text needs a dark: counterpart (design.md: text-slate-600 " <>
             "dark:text-slate-400):\n" <> Enum.join(offenders, "\n")
  end

  # A long class list is a `class={[...]}` literal wrapped over several lines by
  # the formatter, so the light colour and its `dark:` counterpart routinely sit
  # on different lines (`card_footer_link/1` is the standing example). Reading a
  # small window around the hit is what keeps that from reporting as a gap.
  defp dark_half_nearby?(lines, n) do
    lines
    |> Enum.slice(max(n - 3, 0), 5)
    |> Enum.any?(&String.contains?(&1, "dark:text-slate"))
  end

  # The component was fixed first, and eighteen hand-rolled copies of the same
  # heading across nine files still carried the light half alone. Keyed on the
  # recipe's own three utilities, so an unrelated `text-slate-500` (a footer
  # line, a caption) is not dragged in.
  test "no hand-rolled section heading is missing its dark half" do
    recipe = "uppercase tracking-wide text-slate-500"

    offenders =
      for path <- Path.wildcard("lib/**/*.ex") ++ Path.wildcard("lib/**/*.heex"),
          lines = String.split(File.read!(path), "\n"),
          {line, n} <- Enum.with_index(lines, 1),
          String.contains?(line, recipe),
          not dark_half_nearby?(lines, n),
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           "a muted heading on a dark card is ~3.8:1 without its dark half, " <>
             "under AA — append dark:text-slate-400 or use <.section_title>:\n" <>
             Enum.join(offenders, "\n")
  end

  test "the section-title recipe in the design rule carries the dark half" do
    rule =
      @design_rule
      |> File.read!()
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "- **Section title:**"))

    assert rule, "the design rule no longer states a section-title recipe"

    assert rule =~ "dark:text-slate-400",
           "design.md's section-title recipe dropped its dark half, so the next " <>
             "hand-rolled copy will be written without one"
  end
end
