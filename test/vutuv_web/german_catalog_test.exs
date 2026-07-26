defmodule VutuvWeb.GermanCatalogTest do
  @moduledoc """
  vutuv is a German site, so a feature whose labels were never translated ships
  an English interface to nearly every real visitor. That is what happened to
  the whole photo-post UI (issue #1104): the code was written, `mix
  gettext.extract` was never run, and the composer's photo panel, the lightbox
  and the "not public yet" banner all rendered in English on vutuv.de.

  Two things are checked here, both of which failed silently:

  1. **Every string on the interactive surfaces is in the German catalog with a
     translation.** A missing `msgstr` is invisible in tests and in review —
     Gettext just falls through to the English msgid.

  2. **No entry is left `fuzzy`.** `mix gettext.merge` guesses at a new msgid by
     similarity to an existing one and pre-fills its translation, marked fuzzy.
     Those guesses are frequently nonsense — it had filled "Remove photo" with
     the German for "Remove logo" and "Show camera settings" with "Search
     settings" — and a fuzzy entry looks translated to anyone skimming the file.

  Scoped to the modules a member actually clicks through, deliberately: the
  catalog carries a long tail of untranslated legacy prose (long help
  paragraphs on old pages), and failing the build on all of it would just get
  this test deleted. Widen the list when a surface is cleaned up, never narrow
  it to make a red build green.
  """
  use ExUnit.Case, async: true

  @catalog "priv/gettext/de/LC_MESSAGES/default.po"

  # Sources whose user-facing strings must be fully translated.
  @covered [
    "lib/vutuv_web/live/post_live/composer.ex",
    "lib/vutuv_web/components/post_components.ex",
    "lib/vutuv/posts/photo_license.ex"
  ]

  # `gettext("…")` / `ngettext("…", …)` with a plain literal. A string built at
  # runtime cannot be checked here and is not the failure mode this guards.
  @call ~r/\bn?gettext\(\s*"((?:[^"\\]|\\.)+)"/

  defp catalog_blocks do
    @catalog
    |> File.read!()
    |> String.split("\n\n")
  end

  defp msgid(block) do
    case Regex.run(~r/^msgid "((?:[^"\\]|\\.)*)"$/m, block) do
      [_, id] -> unescape(id)
      _ -> nil
    end
  end

  # `\"` and `\\` as a .po file writes them, back to the characters they mean.
  defp unescape(text) do
    text |> String.replace("\\\"", "\"") |> String.replace("\\\\", "\\")
  end

  defp translated?(block) do
    cond do
      Regex.match?(~r/^#,.*\bfuzzy\b/m, block) -> false
      Regex.match?(~r/^msgstr\[\d\] "(?!")/m, block) -> plural_complete?(block)
      true -> Regex.match?(~r/^msgstr "(?:[^"\\]|\\.)+"$/m, block)
    end
  end

  defp plural_complete?(block) do
    ~r/^msgstr\[\d\] "((?:[^"\\]|\\.)*)"$/m
    |> Regex.scan(block)
    |> Enum.all?(fn [_, value] -> value != "" end)
  end

  defp used_strings do
    @covered
    |> Enum.flat_map(fn path ->
      @call |> Regex.scan(File.read!(path)) |> Enum.map(fn [_, literal] -> unescape(literal) end)
    end)
    |> Enum.uniq()
  end

  test "every label on the post composer, card and licence select is translated into German" do
    by_id = Map.new(catalog_blocks(), &{msgid(&1), &1})

    untranslated =
      Enum.reject(used_strings(), fn string ->
        case Map.fetch(by_id, string) do
          {:ok, block} -> translated?(block)
          :error -> false
        end
      end)

    assert untranslated == [],
           """
           These strings have no German translation, so they render in English
           on a German site:

           #{Enum.map_join(untranslated, "\n", &"  - #{&1}")}

           Run `mix gettext.extract --merge`, then translate them in
           #{@catalog}. Check for `#, fuzzy` flags while you are there — a
           merge guesses translations for new strings from similar old ones,
           and its guesses are often wrong.
           """
  end

  test "no string on those surfaces is missing from the catalog entirely" do
    known = MapSet.new(catalog_blocks(), &msgid/1)
    missing = Enum.reject(used_strings(), &MapSet.member?(known, &1))

    assert missing == [],
           """
           These strings are not in the German catalog at all, which means
           `mix gettext.extract --merge` has not been run since they were
           written:

           #{Enum.map_join(missing, "\n", &"  - #{&1}")}
           """
  end
end
