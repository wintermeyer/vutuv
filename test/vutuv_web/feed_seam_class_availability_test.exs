defmodule VutuvWeb.FeedSeamClassAvailabilityTest do
  @moduledoc """
  The "up to here is new" seam is drawn into a document that may be hours old.

  A tab open across a deploy reloads nothing: the socket reconnects to the new
  release and the seam's markup is patched into a page still holding the
  *previous* release's stylesheet. So a class that only this line uses is a
  class that document cannot draw — the v7.347.0 ticker again, which arrived as
  an unstyled paragraph across the tab bar. `.claude/rules/design.md` states the
  check ("grep the tree for it unprefixed") and this file runs it, because the
  seam is exactly the kind of line somebody restyles without reading the comment
  above it.

  The approximation to know: a class another line introduced *in the same
  deploy* passes here and is still absent from the old bundle. It is the cheap
  99 % — the realistic mistake is reaching for a shade nothing else uses.
  """
  use ExUnit.Case, async: true

  @seam_file "lib/vutuv_web/live/post_live/feed.ex"

  test "every class the seam draws with also ships elsewhere in the tree" do
    seam = seam_markup()
    tree = tree_without_seam(seam)

    orphans =
      seam
      |> classes()
      |> Enum.reject(&used_in?(&1, tree))

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

  # Every file the browser could get a class from, read and stripped **once** —
  # the shape the sibling guards use (`brand_link_dark_mode_test.exs`), and here
  # it matters more than there: the needles are a list, so walking the tree per
  # class re-read 59 MB of an 8 MB tree and cost 5× the runtime. Only the seam's
  # own file needs the seam cut out of it.
  defp tree_without_seam(seam) do
    ["lib/**/*.ex", "lib/**/*.heex", "assets/js/**/*.js"]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.map(fn
      @seam_file -> @seam_file |> File.read!() |> String.replace(seam, "") |> markup_only()
      path -> path |> File.read!() |> markup_only()
    end)
  end

  # **Bare, and a substring match is not bare.** `bg-brand-200` lives in this
  # tree only as `hover:bg-brand-200`, which Tailwind emits as
  # `.hover\\:bg-brand-200:hover` — a selector no unhovered element can use, and
  # the very shade the seam's comment says it had to avoid. So the occurrence
  # has to stand alone: nothing that could be a variant prefix or a longer class
  # on either side of it. (First draft of this test used `String.contains?/2`
  # and happily passed that exact class.)
  defp used_in?(class, tree) do
    pattern = ~r/(?<![\w:.\/\[\]-])#{Regex.escape(class)}(?![\w:.\/\[\]-])/

    Enum.any?(tree, &String.match?(&1, pattern))
  end

  # A class *written about* is not a class shipped. `feed.ex`'s own comment
  # names `bg-brand-200` three times while explaining why the seam must not use
  # it — which is what the second draft of this test read as proof that it was
  # available. So comments come out before the match: `#` lines (Elixir) and
  # `<%!-- --%>` blocks (HEEx).
  #
  # Backticked prose does **not** come out, though a `@moduledoc` can name a
  # class that way. Stripping code spans took `assets/js/mention_picker.js` with
  # it, where a one-line template literal is the file's only class assignment —
  # and deleting real markup makes this test fail on a class that does ship,
  # which is the worse of the two wrong answers.
  defp markup_only(source) do
    source
    |> String.replace(~r/<%!--.*?--%>/s, "")
    |> String.replace(~r/^\s*#.*$/m, "")
  end
end
