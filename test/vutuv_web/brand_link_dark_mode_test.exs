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

  Asking for the pair is what keeps it precise: a bare
  `text-brand-600 dark:text-brand-300` is an "on" state and owes this recipe
  nothing.

  A bare `hover:text-brand-700` is a different matter, and this file used to say
  it owed nothing either — it is the slate link that turns brand on hover, so it
  is not *this* recipe. But `brand-700` is `#1e40af`, about **2.3:1** on the dark
  canvas against a resting `dark:text-slate-100` at ~19:1, so hovering such a
  link in dark mode made it harder to read, not easier. That is the second test
  below, and it asks only for the hover half — whatever the resting colour is.
  """
  use ExUnit.Case, async: true

  @light_base "text-brand-600"
  @light_hover "hover:text-brand-700"
  @dark_base "dark:text-brand-400"
  @dark_hover "dark:hover:text-brand-300"

  # `brand-300` is the recipe's own step; the other light steps are equally
  # legible on the dark canvas and several call sites deliberately pick one to
  # match what they rest at. What is refused is having no dark hover at all.
  @dark_hover_steps ~w(text-brand-100 text-brand-200 text-brand-300 text-brand-400)

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

  # Any `(group-)hover:text-brand-700`, whatever it rests at, needs its dark
  # counterpart: 39 call sites carried none and went to ~2.3:1 on hover in dark
  # mode. Deliberately narrower than the recipe test above — it asks nothing
  # about the base colour, so an "on"-state utility is not dragged in.
  test "a brand hover colour always has a dark counterpart" do
    offenders =
      ["lib/**/*.ex", "lib/**/*.heex", "assets/js/**/*.js"]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.flat_map(&unpaired_hovers_in/1)

    assert offenders == [],
           "brand-700 is ~2.3:1 on the dark canvas, so these get HARDER to read " <>
             "on hover. Append dark:(group-)hover:text-brand-300:\n" <>
             Enum.join(offenders, "\n")
  end

  defp unpaired_hovers_in(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} ->
      for prefix <- ["", "group-"],
          has_token?(line, prefix <> @light_hover),
          not Enum.any?(
            @dark_hover_steps,
            &has_token?(line, "dark:" <> prefix <> "hover:" <> &1)
          ),
          # An arbitrary-variant chain (`[&_a]:hover:…`) carries its own dark
          # half spelled the same way; `has_token?/2` cannot see through the
          # bracket, so those are matched loosely here rather than reported.
          not String.contains?(line, "dark:[&"),
          do: "#{file}:#{n} (#{prefix}#{@light_hover})"
    end)
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
