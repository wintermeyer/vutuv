defmodule VutuvWeb.TranslatedCatalogsTest do
  @moduledoc """
  vutuv is a German site with an Italian interface beside it, so a feature whose
  labels were never translated ships an English page to nearly every real
  visitor. That is what happened to the whole photo-post UI (issue #1104): the
  code was written, `mix gettext.extract` was never run, and the composer's
  photo panel, the lightbox and the "not public yet" banner all rendered in
  English on vutuv.de.

  Two things are checked here, per translated locale, both of which failed
  silently:

  1. **Every string on the interactive surfaces is in the catalog with a
     translation.** A missing `msgstr` is invisible in tests and in review —
     Gettext just falls through to the English msgid.

  2. **No entry is left `fuzzy`.** `mix gettext.merge` guesses at a new msgid by
     similarity to an existing one and pre-fills its translation, marked fuzzy.
     Those guesses are frequently nonsense — it had filled "Remove photo" with
     the German for "Remove logo" and "Show camera settings" with "Search
     settings" — and a fuzzy entry looks translated to anyone skimming the file.

  Italian joined in v7.355.1 and paid for its seat on the way in: it had shipped
  in v7.353.0 and drifted within two releases, so the feed-language page stood
  15 strings untranslated with 8 more fuzzy-filled from unrelated entries
  ("Suggested:" as "Post consigliati", "Every language" as "Modifica la
  lingua"). Nothing failed, because only German was gated. `en` is deliberately
  not here: its entries carry no translation at all — English *is* the msgid.

  Scoped to the modules a member actually clicks through, deliberately: the
  catalogs carry a long tail of untranslated legacy prose (long help paragraphs
  on old pages), and failing the build on all of it would just get this test
  deleted. Widen the list when a surface is cleaned up, never narrow it to make
  a red build green.
  """
  use ExUnit.Case, async: true

  # Every locale whose catalog holds real translations. `en` is excluded above.
  @locales ~w(de it)

  # Sources whose user-facing strings must be fully translated. `ui.ex` cannot
  # join as it stands: the scan is textual, so the `gettext("Add entry")` in
  # `card_menu/1`'s @doc EXAMPLE reads as a live string and fails the build for
  # a label nothing renders.
  @covered [
    "lib/vutuv_web/live/post_live/composer.ex",
    "lib/vutuv_web/components/post_components.ex",
    "lib/vutuv/posts/photo_license.ex",
    "lib/vutuv_web/live/tag_new_live.ex",
    # The rename confirmation. Joined the list when its copy was reworked to say
    # plainly that nothing has changed yet: the merge that added those labels
    # fuzzy-filled "Now" with "Nein" (No) and "Not yours yet." with "Noch keine
    # Reposts.", which is precisely the failure this test exists to fail on.
    "lib/vutuv_web/templates/username/confirm.html.heex",
    # The two surfaces that answer a pasted Fediverse address. They joined when
    # a tag actor's address became a tag subscription rather than a refusal, and
    # they earned their place on the way in: extracting that one new sentence
    # fuzzy-filled THREE of the tag wordings #1330 had shipped untranslated —
    # "This topic is not on the Fediverse." with the German for "This profile
    # …", and both `#%{tag}` sentences with the `@%{handle}` ones, i.e. a
    # translation interpolating a binding its own msgid does not carry.
    "lib/vutuv_web/live/fediverse_following_live.ex",
    "lib/vutuv_web/controllers/remote_follow_controller.ex",
    # The feed-language settings page (issue #1672). It belongs here on the
    # general principle, and doubly so for its short labels: "Every language",
    # "Shown as written" and "Suggested:" are exactly the shape the fuzzy
    # matcher fills with something unrelated and nobody notices.
    "lib/vutuv_web/live/feed_languages_live.ex"
  ]

  # `gettext("…")` / `ngettext("…", …)` with a plain literal. A string built at
  # runtime cannot be checked here and is not the failure mode this guards.
  @call ~r/\bn?gettext\(\s*"((?:[^"\\]|\\.)+)"/

  defp catalog(locale), do: "priv/gettext/#{locale}/LC_MESSAGES/default.po"

  defp catalog_blocks(locale) do
    locale
    |> catalog()
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
      Regex.match?(~r/^msgstr\[\d\] /m, block) -> plural_complete?(block)
      true -> msgstr_value(block) != ""
    end
  end

  # Every plural form carries a value, not just the first.
  defp plural_complete?(block) do
    block
    |> String.split(~r/^msgstr\[\d\] /m)
    |> Enum.drop(1)
    |> Enum.all?(&(folded_value(&1) != ""))
  end

  # A .po value longer than one line is **folded**: `msgstr ""` followed by the
  # real text on quoted continuation lines. Reading only the `msgstr` line
  # therefore called a perfectly translated long sentence untranslated, which is
  # what this test did to the fediverse like refusal (issue #1164) although its
  # German had been in the catalog from the start. So the value is the msgstr
  # line plus every quoted line under it.
  defp msgstr_value(block) do
    case String.split(block, ~r/^msgstr /m, parts: 2) do
      [_, tail] -> folded_value(tail)
      _ -> ""
    end
  end

  defp folded_value(tail), do: tail |> String.split("\n") |> Enum.map_join(&quoted_part/1)

  defp quoted_part(line) do
    case Regex.run(~r/^"((?:[^"\\]|\\.)*)"$/, String.trim(line)) do
      [_, value] -> value
      _ -> ""
    end
  end

  defp used_strings do
    @covered
    |> Enum.flat_map(fn path ->
      @call |> Regex.scan(File.read!(path)) |> Enum.map(fn [_, literal] -> unescape(literal) end)
    end)
    |> Enum.uniq()
  end

  for locale <- @locales do
    test "every label on the post composer, card and licence select is translated into #{locale}" do
      locale = unquote(locale)
      by_id = Map.new(catalog_blocks(locale), &{msgid(&1), &1})

      untranslated =
        Enum.reject(used_strings(), fn string ->
          case Map.fetch(by_id, string) do
            {:ok, block} -> translated?(block)
            :error -> false
          end
        end)

      assert untranslated == [],
             """
             These strings have no #{locale} translation, so they render in
             English on a page that asked for that language:

             #{Enum.map_join(untranslated, "\n", &"  - #{&1}")}

             Run `mix gettext.extract --merge`, then translate them in
             #{catalog(locale)}. Check for `#, fuzzy` flags while you are
             there — a merge guesses translations for new strings from similar
             old ones, and its guesses are often wrong.
             """
    end

    test "no string on those surfaces is missing from the #{locale} catalog entirely" do
      locale = unquote(locale)
      known = MapSet.new(catalog_blocks(locale), &msgid/1)
      missing = Enum.reject(used_strings(), &MapSet.member?(known, &1))

      assert missing == [],
             """
             These strings are not in the #{locale} catalog at all, which means
             `mix gettext.extract --merge` has not been run since they were
             written:

             #{Enum.map_join(missing, "\n", &"  - #{&1}")}
             """
    end
  end
end
