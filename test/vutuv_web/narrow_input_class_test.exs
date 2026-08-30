defmodule VutuvWeb.NarrowInputClassTest do
  @moduledoc """
  A control that should be as wide as the word it holds takes
  `VutuvWeb.UI.narrow_input_class/0`. Appending a plain `w-auto` to
  `input_class/0` does not work — that string opens with `w-full` and Tailwind
  emits `.w-auto` before `.w-full`, so the shorter one loses whichever order the
  call site writes them in, and the select silently draws the full width of its
  container. Three forms asked the losing way for months: the saved-search
  cadence, an organization's kind, its domain verification method.

  A variant (`sm:w-auto`) wins on its own, its rules coming after the bare ones,
  so this only refuses the bare utility.
  """
  use ExUnit.Case, async: true

  # Whitespace-collapsed, because whether the composed class list fits on one
  # source line is `mix format`'s decision, not the author's — a per-line scan
  # reports clean on exactly the regression it exists for the moment a
  # `class={[…]}` grows long enough to be broken across lines.
  @composed ~r/input_class\(\)[^\]]{0,200}?(?<![:\w-])w-auto(?![!\w-])/

  test "no field composes input_class/0 with a plain w-auto" do
    offenders =
      "lib/vutuv_web/**/*.{ex,heex}"
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        source = File.read!(path)

        String.contains?(source, "input_class(") and
          Regex.match?(@composed, String.replace(source, ~r/\s+/, " "))
      end)

    assert offenders == [], """
    These compose input_class/0 with a bare `w-auto`, which never wins:

    #{Enum.join(offenders, "\n")}

    Call `narrow_input_class/0` instead — it carries the `w-auto!` that does,
    and the `max-w-full` that keeps a long option inside a narrow column.
    """
  end
end
