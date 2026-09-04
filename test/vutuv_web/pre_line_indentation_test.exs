defmodule VutuvWeb.PreLineIndentationTest do
  @moduledoc """
  An element that keeps the newlines in its markup must not open with the
  template's own indentation.

  `whitespace-pre-line` (and `pre-wrap`) tell the browser to render every
  newline inside the element, and HEEx hands the text over exactly as the
  template is written — so

      <p class="whitespace-pre-line">
        {@account.summary}
      </p>

  renders a blank line before the first word. Nothing warns about it: the page
  compiles, the tests pass, and the reader sees a paragraph that starts one line
  too low. Where the element is also clamped (`line-clamp-2`, `.post-clamp`,
  `.notif-clamp`), that blank line is one of the few the reader gets, which is
  how the account card came to show a single line of self-description under an
  empty one (2026-09-04).

  The fix is to write the expression against its tags, `>{@account.summary}</p>`,
  which is how every other such paragraph in the app is written. `mix format`
  cannot do it for you — `.formatter.exs` binds no `.heex` files.
  """
  use ExUnit.Case, async: true

  # The opening tag may run over several lines, so this matches from the tag's
  # `<` to its `>` and then asks what follows: a newline plus an interpolation is
  # the defect, anything else (text, a child element, the expression on the same
  # line) is fine.
  @offender ~r/<[a-zA-Z][^<>]*whitespace-pre-(?:line|wrap)[^<>]*>[ \t]*\r?\n\s*\{/

  test "no element that keeps its newlines opens on an indented expression" do
    offenders =
      for path <- Path.wildcard("lib/**/*.heex") ++ Path.wildcard("lib/**/*.ex"),
          source = File.read!(path),
          [{offset, _length} | _] <- Regex.scan(@offender, source, return: :index) do
        line = source |> binary_part(0, offset) |> String.split("\n") |> length()
        "#{path}:#{line}"
      end

    assert offenders == [],
           """
           These elements preserve their newlines and open on an indented \
           expression, so each renders a blank first line:

           #{Enum.join(offenders, "\n")}

           Write the expression against the tags instead: >{@thing}</p>
           """
  end
end
