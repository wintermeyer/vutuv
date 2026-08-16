defmodule VutuvWeb.BrandLinkDarkModeTest do
  @moduledoc """
  The brand text-link recipe (`.claude/rules/design.md`) had drifted into a
  dozen spellings — 83 call sites carried no `dark:` variant at all, so those
  links lost contrast in dark mode — until the 2026-07-30 sweep normalized
  every one to the canonical pair. This guard keeps it that way.

  What identifies a link is **both light halves on one line under the same
  variant chain**, not the two words side by side. The first version matched the
  literal `text-brand-600 hover:text-brand-700`, so two spellings of the very
  same recipe walked past it, both of them genuinely missing their dark pair: an
  arbitrary variant (`[&_a]:text-brand-600 [&_a]:hover:text-brand-700`, how the
  legal pages colour the links inside a Markdown body) and a class written
  between the two (`text-brand-600 underline hover:text-brand-700`).

  Asking for the pair is what keeps it precise. Each of these utilities has a
  second life on its own — a bare `hover:text-brand-700` is the slate link that
  turns brand on hover, a bare `text-brand-600 dark:text-brand-300` is an "on"
  state — and neither owes anything to this recipe.
  """
  use ExUnit.Case, async: true

  @light_base "text-brand-600"
  @light_hover "hover:text-brand-700"
  @dark_base "dark:text-brand-400"
  @dark_hover "dark:hover:text-brand-300"

  test "every brand text link carries the canonical dark-mode pair" do
    offenders =
      ["lib/**/*.ex", "lib/**/*.heex", "assets/js/**/*.js"]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.flat_map(&offenders_in/1)

    assert offenders == [],
           "Brand text links missing the canonical dark pair — use\n" <>
             "  #{@light_base} #{@light_hover} #{@dark_base} #{@dark_hover}\n" <>
             "(a variant chain repeats verbatim under dark:, see .claude/rules/design.md):\n" <>
             Enum.join(offenders, "\n")
  end

  defp offenders_in(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} ->
      for chain <- unpaired_chains(line), do: "#{file}:#{n} (#{chain}#{@light_base})"
    end)
  end

  # The variant chains this line spells the whole light recipe under and does
  # not spell the whole dark one under.
  defp unpaired_chains(line) do
    ~r/([^\s"'{}=]*)#{Regex.escape(@light_base)}/
    |> Regex.scan(line)
    |> Enum.map(fn [_match, chain] -> chain end)
    |> Enum.uniq()
    |> Enum.reject(&String.contains?(&1, "dark:"))
    |> Enum.filter(&has_token?(line, &1 <> @light_hover))
    |> Enum.reject(fn chain ->
      has_token?(line, "dark:" <> chain <> String.trim_leading(@dark_base, "dark:")) and
        has_token?(line, "dark:" <> chain <> String.trim_leading(@dark_hover, "dark:"))
    end)
  end

  # A whole class, not a substring of one: without the boundary,
  # `group-hover:text-brand-700` answers for `hover:text-brand-700` and the
  # guard then asks for a dark half under the wrong variant.
  defp has_token?(line, token) do
    Regex.match?(~r/(?<![^\s"'{}=])#{Regex.escape(token)}/, line)
  end
end
