defmodule VutuvWeb.FeedSeamClassAvailabilityTest do
  @moduledoc """
  The "up to here is new" seam is drawn into a document that may be hours old.

  A tab open across a deploy reloads nothing: the socket reconnects to the new
  release and the seam's markup is patched into a page still holding the
  *previous* release's stylesheet. So a class that only this line uses is a
  class that document cannot draw — the v7.347.0 ticker again, which arrived as
  an unstyled paragraph across the tab bar. `.claude/rules/design.md` states the
  check ("grep the tree for it unprefixed") and `VutuvWeb.ClassAvailability`
  runs it, because the seam is exactly the kind of line somebody restyles
  without reading the comment above it.

  The approximation to know: a class another line introduced *in the same
  deploy* passes here and is still absent from the old bundle. It is the cheap
  99 % — the realistic mistake is reaching for a shade nothing else uses.
  """
  use ExUnit.Case, async: true

  alias VutuvWeb.ClassAvailability

  @seam_file "lib/vutuv_web/live/post_live/feed.ex"

  test "every class the seam draws with also ships elsewhere in the tree" do
    orphans = ClassAvailability.orphans([seam_markup()], &classes/1)

    assert orphans == [],
           "These classes appear only in the feed's `visit_seam/1`, so the previous\n" <>
             "release's stylesheet has no rule for them and a tab open across a deploy\n" <>
             "draws the seam unstyled. Pick a class the tree already uses bare:\n" <>
             Enum.join(orphans, "\n")
  end

  # The `~H` heredoc of `visit_seam/1`, from its `def` to the closing `"""`.
  # It says so rather than raising a `MatchError` on nil: renaming or
  # reformatting that function is the likeliest way to break this guard, and
  # "no match of right hand side value: nil" names neither.
  defp seam_markup do
    source = File.read!(@seam_file)

    case Regex.run(~r/defp visit_seam\(assigns\) do.*?~H"""\n(.*?)\n\s*"""/s, source) do
      [_, markup] -> markup
      nil -> flunk("no `visit_seam/1` with an ~H heredoc in #{@seam_file}")
    end
  end

  # Only the literal `class="…"` form is readable here, so a seam restyled to
  # this codebase's other spelling — `class={["h-0.5", @x && "…"]}` — would hand
  # back fewer classes, or none at all, and this test would pass green over
  # markup it never read. That is the vacuous assertion, so it fails first.
  defp classes(markup) do
    refute markup =~ ~r/class=\{/,
           "The seam builds its class list dynamically; `classes/1` reads only the " <>
             "literal form and would vouch for nothing. Teach it the other one."

    ~r/class="([^"]+)"/
    |> Regex.scan(markup)
    |> Enum.flat_map(fn [_, list] -> String.split(list) end)
    |> Enum.uniq()
  end
end
