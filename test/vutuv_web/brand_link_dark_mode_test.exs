defmodule VutuvWeb.BrandLinkDarkModeTest do
  @moduledoc """
  The brand text-link recipe (`.claude/rules/design.md`) had drifted into a
  dozen spellings — 83 call sites carried no `dark:` variant at all, so those
  links lost contrast in dark mode — until the 2026-07-30 sweep normalized
  every one to the canonical pair. This guard keeps it that way: wherever the
  light half appears in the sources, the canonical dark half must follow
  verbatim, so dark mode can never silently lose a link again (the "clean
  dark mode" house rule).
  """
  use ExUnit.Case, async: true

  @canonical "text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
  @light "text-brand-600 hover:text-brand-700"

  test "every brand text link carries the canonical dark-mode pair" do
    offenders =
      ["lib/**/*.ex", "lib/**/*.heex", "assets/js/**/*.js"]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} ->
          # Remove every canonical occurrence first: whatever light half is
          # left over is one that lacks its dark pair.
          String.contains?(line, @light) and
            line |> String.replace(@canonical, "") |> String.contains?(@light)
        end)
        |> Enum.map(fn {_line, n} -> "#{file}:#{n}" end)
      end)

    assert offenders == [],
           "Brand links missing the canonical dark pair — use\n  #{@canonical}\n" <>
             "(see the text-link recipe in .claude/rules/design.md):\n" <>
             Enum.join(offenders, "\n")
  end
end
