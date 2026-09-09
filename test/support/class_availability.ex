defmodule VutuvWeb.ClassAvailability do
  @moduledoc """
  The check behind every "this markup is patched into an old document" guard:
  **does every Tailwind class this markup uses also ship somewhere else in the
  tree?**

  A tab left open across a deploy reloads nothing — the socket reconnects to the
  new release and the markup is patched into a page still holding the *previous*
  release's stylesheet — so a class only one new line uses is a class that
  document cannot draw. That is the v7.347.0 ticker, which arrived as an
  unstyled paragraph across the tab bar and which no clock ever took away.

  Two guards ask it (the feed's "up to here is new" seam and the profile's Press
  card) and the third would have forked it again, which is how the two that
  existed had already come to disagree about whether `assets/css` counts as part
  of the tree. Each caller keeps its own extractor — where the markup lives and
  how it spells its classes is the part that really differs — and hands the
  result here.

  The approximation to know: a class another line introduces *in the same
  deploy* passes here and is still absent from the old bundle. It is the cheap
  99 % — the realistic mistake is reaching for a shade nothing else uses.
  """

  @sources ["lib/**/*.ex", "lib/**/*.heex", "assets/js/**/*.js", "assets/css/**/*.css"]

  @doc """
  The classes in `own` (a list of markup strings) that appear **nowhere else**
  in the tree — `[]` when every one of them ships.

  `classes` is the caller's extractor, run over each string in `own`; the same
  strings are cut out of every file before the search, so markup cannot vouch
  for itself.
  """
  def orphans(own, classes) when is_list(own) and is_function(classes, 1) do
    tree = tree_without(own)

    own
    |> Enum.flat_map(classes)
    |> Enum.uniq()
    |> Enum.reject(&used_in?(&1, tree))
  end

  # Every file the browser could get a class from, read and stripped **once**.
  # Walking the tree per class re-read 59 MB of an 8 MB tree and cost 5× the
  # runtime, so the needles move and the haystack stands still.
  defp tree_without(own) do
    @sources
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.map(&File.read!/1)
    |> Enum.map(fn source -> Enum.reduce(own, source, &String.replace(&2, &1, "")) end)
    |> Enum.map(&markup_only/1)
  end

  # **Bare, and a substring match is not bare.** `bg-brand-200` lives in this
  # tree only as `hover:bg-brand-200`, which Tailwind emits as
  # `.hover\\:bg-brand-200:hover` — a selector no unhovered element can use, and
  # the very shade the feed seam's comment says it had to avoid. So the
  # occurrence has to stand alone: nothing that could be a variant prefix or a
  # longer class on either side of it. (The first draft of this used
  # `String.contains?/2` and happily passed that exact class.)
  defp used_in?(class, tree) do
    pattern = ~r/(?<![\w:.\/\[\]-])#{Regex.escape(class)}(?![\w:.\/\[\]-])/

    Enum.any?(tree, &String.match?(&1, pattern))
  end

  # A class *written about* is not a class shipped. `feed.ex`'s own comment names
  # `bg-brand-200` three times while explaining why the seam must not use it —
  # which an earlier draft read as proof that it was available. So comments come
  # out before the match: `#` lines (Elixir) and `<%!-- --%>` blocks (HEEx).
  #
  # Backticked prose does **not** come out, though a `@moduledoc` can name a
  # class that way. Stripping code spans took `assets/js/mention_picker.js` with
  # it, where a one-line template literal is the file's only class assignment —
  # and deleting real markup makes a caller fail on a class that does ship,
  # which is the worse of the two wrong answers.
  defp markup_only(source) do
    source
    |> String.replace(~r/<%!--.*?--%>/s, "")
    |> String.replace(~r/^\s*#.*$/m, "")
  end
end
